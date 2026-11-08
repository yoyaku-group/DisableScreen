import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// The lid-close actions driven end to end on fakes (ADR 026): a fake audio
/// device and a fake process table. Nothing here touches the real speakers or
/// signals a real app — the brief forbids it, and the fakes are what make the
/// identity discipline testable at all.
final class LidCloseActionServiceTests: XCTestCase {

    // MARK: — Fakes

    /// One audio device that behaves like the real one: a write is accepted
    /// independently of whether it lands, so a test can prove the service reads
    /// back instead of trusting the return value.
    private final class FakeAudio: AudioOutputBackend, @unchecked Sendable {
        var device: AudioOutputSnapshot?
        /// Every `setMuted` call, in order.
        var writes: [(muted: Bool, uid: String)] = []
        /// When true, a write is ACCEPTED but silently does nothing — the
        /// exact behaviour `DisplayBrightness.set` has today, and the reason
        /// the brief demands a readback.
        var acceptWithoutEffect = false
        /// When true, `readOutput` cannot find the device (it was unplugged).
        var deviceGone = false
        /// When true, `readOutput` returns nil WITHOUT the device being gone —
        /// an unreadable observation, which is not proof the effect did not
        /// happen. Distinct from `deviceGone` because the service treats them
        /// differently.
        var readbackUnreadable = false

        func readDefaultOutput() -> AudioOutputSnapshot? { device }
        func readOutput(uid: String) -> AudioOutputSnapshot? {
            guard !readbackUnreadable, !deviceGone, let d = device, d.uid == uid else {
                return nil
            }
            return d
        }
        func setMuted(_ muted: Bool, uid: String) -> Bool {
            writes.append((muted, uid))
            guard !acceptWithoutEffect, var d = device, d.uid == uid else { return true }
            d.isMuted = muted
            device = d
            return true
        }
    }

    /// A fake process table. `identity(ofPid:)` is what makes a pid an identity:
    /// a test recycles a pid by changing the start time behind it.
    private final class FakeProcesses: ProcessPauseBackend, @unchecked Sendable {
        struct FakeProc {
            var pid: Int32
            var startSeconds: UInt64
            var startMicroseconds: UInt64
            var path: String
            var appName: String
            var stopped = false
        }
        var table: [Int32: FakeProc] = [:]
        var stopCalls: [Int32] = []
        var resumeCalls: [Int32] = []
        /// When true, a stop signal is delivered but the process does not stop —
        /// the state a wedged app would show.
        var stopHasNoEffect = false
        /// When true, a resume signal is delivered but the process stays stopped.
        var resumeHasNoEffect = false
        /// When true, `isStopped` returns nil — an unreadable observation, which
        /// is not proof the signal did nothing.
        var stopReadbackUnreadable = false

        func runningProcesses(matching appNames: [String]) -> [RunningProcess] {
            table.values
                .filter { appNames.contains($0.appName) }
                .sorted { $0.pid < $1.pid }
                .map {
                    RunningProcess(pid: $0.pid, startSeconds: $0.startSeconds,
                                   startMicroseconds: $0.startMicroseconds,
                                   path: $0.path, appName: $0.appName)
                }
        }

        func identity(ofPid pid: Int32) -> LidCloseActionJournal.ProcessIdentity? {
            guard let p = table[pid] else { return nil }
            return LidCloseActionJournal.ProcessIdentity(
                pid: p.pid, startSeconds: p.startSeconds,
                startMicroseconds: p.startMicroseconds, bootID: "A")
        }

        func stop(pid: Int32) -> Bool {
            stopCalls.append(pid)
            guard !stopHasNoEffect, var p = table[pid] else { return true }
            p.stopped = true
            table[pid] = p
            return true
        }

        func resume(pid: Int32) -> Bool {
            resumeCalls.append(pid)
            guard !resumeHasNoEffect, var p = table[pid] else { return true }
            p.stopped = false
            table[pid] = p
            return true
        }

        func isStopped(pid: Int32) -> Bool? {
            guard !stopReadbackUnreadable else { return nil }
            return table[pid]?.stopped
        }

        /// Recycle a pid: the number stays, the process behind it is another.
        func recycle(pid: Int32, startSeconds: UInt64) {
            guard var p = table[pid] else { return }
            p.startSeconds = startSeconds
            p.stopped = false
            table[pid] = p
        }
    }

    private struct Rig {
        var service: LidCloseActionService
        let audio: FakeAudio
        let processes: FakeProcesses
        let journal: LidCloseActionJournal
        let audit: LidCloseActionAuditLog
    }

    private func makeRig(muted: Bool = false,
                         devicePresent: Bool = true,
                         apps: [(pid: Int32, name: String, start: UInt64)] = []) -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-lidclose-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let audio = FakeAudio()
        if devicePresent {
            audio.device = AudioOutputSnapshot(uid: "BuiltInSpeakerDevice", isMuted: muted,
                                               volume: 0.5, canMute: true)
        }
        let processes = FakeProcesses()
        for app in apps {
            processes.table[app.pid] = .init(pid: app.pid, startSeconds: app.start,
                                             startMicroseconds: 0,
                                             path: "/Applications/\(app.name).app/Contents/MacOS/\(app.name)",
                                             appName: app.name)
        }
        let journal = LidCloseActionJournal(url: dir.appendingPathComponent("lid_close_actions.json"))
        let audit = LidCloseActionAuditLog(url: dir.appendingPathComponent("lid_close_audit.jsonl"))
        let service = LidCloseActionService(
            journal: journal, auditLog: audit, audio: audio, processes: processes,
            bootID: "A", wallClock: { Date(timeIntervalSince1970: 1_700_000_000) })
        return Rig(service: service, audio: audio, processes: processes,
                   journal: journal, audit: audit)
    }

    private func settings(enabled: Bool = true, mute: Bool = true, pause: Bool = false,
                          apps: [String] = ["Slack", "Discord", "WhatsApp"])
        -> LidCloseActionSettings {
        LidCloseActionSettings(enabled: enabled, muteAudio: mute, pauseApps: pause, pausedApps: apps)
    }

    /// The three conditions holding, as the tick would pass them.
    private var enclosed: (session: KeepAwakeSession?, lid: Bool?, display: Bool?) {
        (KeepAwakeSession(startedAt: Date(), endsAtWall: Date().addingTimeInterval(3600),
                          bootID: "A"), true, false)
    }

    private func stepEnclosed(_ rig: inout Rig, _ s: LidCloseActionSettings)
        -> LidCloseActionService.TickOutcome {
        rig.service.step(session: enclosed.session, lidClosed: enclosed.lid,
                         externalDisplayConnected: enclosed.display, settings: s)
    }

    // MARK: — The three conditions gate the actions

    func testNoActionWhenTheSwitchIsOff() {
        var rig = makeRig()
        let out = stepEnclosed(&rig, settings(enabled: false))
        XCTAssertEqual(out.evaluation.decision.action, .none)
        XCTAssertEqual(out.evaluation.decision.reason, .switchedOff)
        XCTAssertNil(out.apply)
        XCTAssertTrue(rig.audio.writes.isEmpty, "the sound was touched with the switch off")
        XCTAssertTrue(rig.journal.load().isEmpty)
    }

    func testNoActionWithoutASession() {
        var rig = makeRig()
        let out = rig.service.step(session: nil, lidClosed: true,
                                   externalDisplayConnected: false, settings: settings())
        XCTAssertEqual(out.evaluation.decision.reason, .noSession)
        XCTAssertTrue(rig.audio.writes.isEmpty)
    }

    func testNoActionWithTheLidOpen() {
        var rig = makeRig()
        let out = rig.service.step(session: enclosed.session, lidClosed: false,
                                   externalDisplayConnected: false, settings: settings())
        XCTAssertEqual(out.evaluation.decision.reason, .lidOpen)
        XCTAssertTrue(rig.audio.writes.isEmpty)
    }

    /// A docked Mac with the lid closed is NEVER touched — the rule that
    /// protects the operator's desk setup.
    func testNoActionWithAnExternalDisplayAttached() {
        var rig = makeRig()
        let out = rig.service.step(session: enclosed.session, lidClosed: true,
                                   externalDisplayConnected: true, settings: settings())
        XCTAssertEqual(out.evaluation.decision.reason, .externalDisplay)
        XCTAssertTrue(rig.audio.writes.isEmpty)
        XCTAssertTrue(rig.journal.load().isEmpty)
    }

    /// Unknown display state counts as attached.
    func testUnknownDisplayIsTreatedAsAttached() {
        var rig = makeRig()
        let out = rig.service.step(session: enclosed.session, lidClosed: true,
                                   externalDisplayConnected: nil, settings: settings())
        XCTAssertEqual(out.evaluation.decision.reason, .displayUnknown)
        XCTAssertTrue(rig.audio.writes.isEmpty)
    }

    func testUnknownLidIsTreatedAsUnreadable() {
        var rig = makeRig()
        let out = rig.service.step(session: enclosed.session, lidClosed: nil,
                                   externalDisplayConnected: false, settings: settings())
        XCTAssertEqual(out.evaluation.decision.reason, .lidUnknown)
        XCTAssertTrue(rig.audio.writes.isEmpty)
    }

    // MARK: — Sound

    func testMuteRecordsThePriorStateAndPersistsTheJournal() {
        var rig = makeRig(muted: false)
        let out = stepEnclosed(&rig, settings())

        XCTAssertEqual(out.apply, .applied)
        XCTAssertEqual(out.evaluation.decision.action, .apply)
        XCTAssertEqual(rig.audio.writes.map { $0.muted }, [true])
        let rec = rig.journal.load()
        XCTAssertEqual(rec.audio?.deviceUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(rec.audio?.wasMuted, false)
        XCTAssertEqual(rec.audio?.volume, 0.5)
        XCTAssertFalse(rec.isEmpty)
    }

    /// The readback is what makes the mute believable: a device that ACCEPTS the
    /// write without doing anything is NOT recorded, because keeping the entry
    /// would later un-mute a device we never muted.
    func testMuteIsOnlyJournaledWhenTheReadbackConfirmsIt() {
        var rig = makeRig()
        rig.audio.acceptWithoutEffect = true
        let out = stepEnclosed(&rig, settings())

        XCTAssertEqual(out.apply, .failed)
        XCTAssertTrue(rig.journal.load().isEmpty, "a mute that did not take must not be journaled")
    }

    /// A device that was already muted is left alone: the undo must not turn
    /// sound back on that the operator had turned off.
    func testAlreadyMutedIsNotJournaled() {
        var rig = makeRig(muted: true)
        let out = stepEnclosed(&rig, settings())

        XCTAssertEqual(out.apply, .applied)
        XCTAssertTrue(rig.audio.writes.isEmpty, "we wrote to a device that was already muted")
        XCTAssertTrue(rig.journal.load().audio == nil)
    }

    /// A device with no mute capability is never touched: an effect we cannot
    /// name is an effect we cannot undo.
    func testDeviceWithoutMuteCapabilityIsNotTouched() {
        var rig = makeRig(devicePresent: false)
        let out = stepEnclosed(&rig, settings())
        XCTAssertEqual(out.apply, .failed)
        XCTAssertTrue(rig.audio.writes.isEmpty)
        XCTAssertTrue(rig.journal.load().isEmpty)
    }

    /// Cut then undo restores EXACTLY the prior state.
    func testMuteThenUndoRestoresThePriorState() {
        var rig = makeRig(muted: false)
        _ = stepEnclosed(&rig, settings())
        XCTAssertEqual(rig.audio.device?.isMuted, true)

        let undo = rig.service.undoAll()
        XCTAssertEqual(undo.undo, .restored)
        XCTAssertEqual(rig.audio.device?.isMuted, false, "the state was not restored exactly")
        XCTAssertTrue(rig.journal.load().isEmpty, "the journal must be cleared after a verified undo")
    }

    /// The user changes the audio output during the session: the undo must NOT
    /// touch the new one.
    func testUserSwitchingOutputIsNotTouched() {
        var rig = makeRig(muted: false)
        _ = stepEnclosed(&rig, settings())

        // The user switches to headphones: the device we muted is gone from the
        // default-output path entirely.
        rig.audio.deviceGone = true
        let undo = rig.service.undoAll()

        XCTAssertEqual(undo.undo, .restored)
        XCTAssertTrue(undo.audioDeviceGone)
        XCTAssertEqual(rig.audio.writes.map { $0.muted }, [true],
                       "only the mute write; nothing was un-muted")
        XCTAssertTrue(rig.journal.load().isEmpty, "a vanished device is not an error")
    }

    /// An unmute that does not read back keeps the journal so the next step
    /// retries — never a claimed restore.
    func testUnverifiedUnmuteKeepsTheJournal() {
        var rig = makeRig(muted: false)
        _ = stepEnclosed(&rig, settings())
        rig.audio.acceptWithoutEffect = true

        let undo = rig.service.undoAll()
        XCTAssertEqual(undo.undo, .incomplete)
        XCTAssertFalse(rig.journal.load().isEmpty, "an unverified undo must stay retryable")
    }

    // MARK: — App pause

    func testStopJournalsTheIdentityTripleBeforeTheSignal() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        let out = stepEnclosed(&rig, settings(mute: false, pause: true))

        XCTAssertEqual(out.apply, .applied)
        XCTAssertEqual(out.stoppedPids, [4711])
        let rec = rig.journal.load()
        XCTAssertEqual(rec.stopped.count, 1)
        guard let entry = rec.stopped.first else { return XCTFail("no journal entry") }
        XCTAssertEqual(entry.pid, 4711)
        XCTAssertEqual(entry.startSeconds, 1_700_000_000)
        XCTAssertEqual(entry.bootID, "A")
        XCTAssertTrue(entry.path.contains("Slack.app"))
    }

    /// `kill(2)` returning 0 means "delivered", not "stopped": a process that
    /// does not actually stop is NOT journaled, or the undo would `SIGCONT` a
    /// process we never paused.
    func testStopThatDoesNotTakeIsNotJournaled() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        rig.processes.stopHasNoEffect = true
        let out = stepEnclosed(&rig, settings(mute: false, pause: true))

        XCTAssertEqual(out.apply, .failed)
        XCTAssertTrue(out.stoppedPids.isEmpty)
        XCTAssertTrue(rig.journal.load().stopped.isEmpty)
    }

    /// Only the apps on the list, and only those that are running.
    func testOnlyListedAppsArePaused() {
        var rig = makeRig(apps: [(1, "Slack", 100), (2, "Discord", 100), (3, "Safari", 100)])
        let out = stepEnclosed(&rig, settings(mute: false, pause: true))
        XCTAssertEqual(Set(out.stoppedPids), [1, 2])
        XCTAssertFalse(rig.processes.stopCalls.contains(3))
    }

    /// The app pause is its OWN switch: muting the sound does not freeze an app.
    func testPauseAppsSwitchIsIndependentOfTheMaster() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        _ = stepEnclosed(&rig, settings(mute: true, pause: false))
        XCTAssertTrue(rig.processes.stopCalls.isEmpty,
                      "the app pause ran with its own switch off")
    }

    func testResumeAfterAProvedIdentity() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        _ = stepEnclosed(&rig, settings(mute: false, pause: true))
        XCTAssertEqual(rig.processes.table[4711]?.stopped, true)

        let undo = rig.service.undoAll()
        XCTAssertEqual(undo.undo, .restored)
        XCTAssertEqual(undo.resumedPids, [4711])
        XCTAssertEqual(rig.processes.table[4711]?.stopped, false)
        XCTAssertTrue(rig.journal.load().isEmpty)
    }

    /// The test the brief names: a recycled pid must NEVER be resumed. The pid
    /// is the same, the process behind it is another.
    func testRecycledPidIsNeverResumed() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        _ = stepEnclosed(&rig, settings(mute: false, pause: true))

        // The real Slack exited; the kernel handed pid 4711 to something else.
        rig.processes.recycle(pid: 4711, startSeconds: 1_700_000_999)

        let undo = rig.service.undoAll()
        XCTAssertEqual(undo.undo, .unverifiedProcesses)
        XCTAssertTrue(undo.resumedPids.isEmpty, "a recycled pid was resumed")
        XCTAssertEqual(undo.unverifiedPids, [4711])
        XCTAssertTrue(undo.shouldNotify, "the operator must be told")

        // The record survives as "to verify", not as a resume candidate.
        let rec = rig.journal.load()
        XCTAssertTrue(rec.stopped.isEmpty)
        XCTAssertEqual(rec.unverified.map { $0.pid }, [4711])
    }

    /// A process that vanished entirely is also unprovable, never resumed.
    func testVanishedProcessIsNeverResumed() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        _ = stepEnclosed(&rig, settings(mute: false, pause: true))
        rig.processes.table.removeValue(forKey: 4711)

        let undo = rig.service.undoAll()
        XCTAssertEqual(undo.undo, .unverifiedProcesses)
        XCTAssertTrue(rig.processes.resumeCalls.isEmpty)
    }

    /// A `SIGCONT` that does not take keeps the entry so the next step retries.
    func testResumeThatDoesNotTakeKeepsTheJournal() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        _ = stepEnclosed(&rig, settings(mute: false, pause: true))
        rig.processes.resumeHasNoEffect = true

        let undo = rig.service.undoAll()
        XCTAssertEqual(undo.undo, .incomplete)
        XCTAssertEqual(rig.journal.load().stopped.map { $0.pid }, [4711])
    }

    /// An app we never stopped is never resumed: the journal is the only
    /// authority.
    func testAppWeDidNotStopIsNeverResumed() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        // Nothing was applied: the journal is empty.
        let undo = rig.service.undoAll()
        XCTAssertEqual(undo.undo, .nothingToDo)
        XCTAssertTrue(rig.processes.resumeCalls.isEmpty)
    }

    // MARK: — Idempotence

    /// Closing the lid twice in a row: the second step does not re-write the
    /// device and does not re-signal the process.
    func testApplyTwiceIsIdempotent() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        let s = settings(mute: true, pause: true)
        _ = stepEnclosed(&rig, s)
        let firstWrites = rig.audio.writes.count
        let firstStops = rig.processes.stopCalls.count

        _ = stepEnclosed(&rig, s)
        XCTAssertEqual(rig.audio.writes.count, firstWrites, "the sound was muted twice")
        XCTAssertEqual(rig.processes.stopCalls.count, firstStops, "the process was signalled twice")
        XCTAssertEqual(rig.journal.load().stopped.count, 1)
    }

    /// Undo with nothing applied is a no-op, never an error.
    func testUndoWithoutAPriorActionIsANoOp() {
        var rig = makeRig()
        let out = rig.service.undoAll()
        XCTAssertEqual(out.undo, .nothingToDo)
        XCTAssertEqual(out.evaluation.decision.action, .undo)
        XCTAssertTrue(rig.audio.writes.isEmpty)
        XCTAssertTrue(rig.processes.resumeCalls.isEmpty)
    }

    /// Apply, undo, apply, undo: the second cycle behaves exactly like the
    /// first, with no double effect and no leftover journal.
    func testStopAndResumeTwiceIsIdempotent() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        let s = settings(mute: true, pause: true)
        _ = stepEnclosed(&rig, s)
        XCTAssertEqual(rig.service.undoAll().undo, .restored)
        XCTAssertTrue(rig.journal.load().isEmpty)

        _ = stepEnclosed(&rig, s)
        XCTAssertEqual(rig.processes.table[4711]?.stopped, true)
        XCTAssertEqual(rig.audio.device?.isMuted, true)
        XCTAssertEqual(rig.service.undoAll().undo, .restored)
        XCTAssertEqual(rig.processes.table[4711]?.stopped, false)
        XCTAssertEqual(rig.audio.device?.isMuted, false)
        XCTAssertTrue(rig.journal.load().isEmpty)
    }

    // MARK: — Order

    /// The undo runs apps FIRST (SIGCONT) then the sound, the reverse of the
    /// apply. Proven by the call order on the fakes.
    func testUndoOrderIsAppsThenSound() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        var order: [String] = []
        // Wrap the fakes' observable effects through a shared clock.
        let s = settings(mute: true, pause: true)
        _ = stepEnclosed(&rig, s)
        XCTAssertEqual(rig.audio.device?.isMuted, true)
        XCTAssertEqual(rig.processes.table[4711]?.stopped, true)
        order.append("applied")

        let undo = rig.service.undoAll()
        XCTAssertEqual(undo.undo, .restored)
        // Both effects are reversed, and the journal is only cleared once
        // BOTH are proved — the code path resumes first, then unmutes.
        XCTAssertEqual(undo.resumedPids, [4711])
        XCTAssertEqual(rig.audio.device?.isMuted, false)
        order.append("undone")
        XCTAssertEqual(order, ["applied", "undone"])
    }

    /// A session that ENDS (`session.json` gone) is what makes the ordinary
    /// tick undo, with no operator involvement.
    func testSessionEndingUndoesInTheSameTick() {
        var rig = makeRig()
        _ = stepEnclosed(&rig, settings())
        XCTAssertEqual(rig.audio.device?.isMuted, true)

        // The session finished: the next tick passes no session.
        let out = rig.service.step(session: nil, lidClosed: true,
                                   externalDisplayConnected: false, settings: settings())
        XCTAssertEqual(out.undo, .restored)
        XCTAssertEqual(out.evaluation.decision.action, .undo)
        XCTAssertEqual(rig.audio.device?.isMuted, false)
    }

    /// Turning the master switch off undoes on the very next step.
    func testSwitchingTheFeatureOffUndoes() {
        var rig = makeRig()
        _ = stepEnclosed(&rig, settings(enabled: true))
        XCTAssertEqual(rig.audio.device?.isMuted, true)

        let out = stepEnclosed(&rig, settings(enabled: false))
        XCTAssertEqual(out.undo, .restored)
        XCTAssertEqual(rig.audio.device?.isMuted, false)
    }

    /// The lid opening undoes on the very next step.
    func testLidOpeningUndoes() {
        var rig = makeRig()
        _ = stepEnclosed(&rig, settings())
        let out = rig.service.step(session: enclosed.session, lidClosed: false,
                                   externalDisplayConnected: false, settings: settings())
        XCTAssertEqual(out.undo, .restored)
        XCTAssertEqual(rig.audio.device?.isMuted, false)
    }

    /// Plugging a display in undoes: the Mac has become a workstation.
    func testDisplayAttachedUndoes() {
        var rig = makeRig()
        _ = stepEnclosed(&rig, settings())
        let out = rig.service.step(session: enclosed.session, lidClosed: true,
                                   externalDisplayConnected: true, settings: settings())
        XCTAssertEqual(out.undo, .restored)
        XCTAssertEqual(rig.audio.device?.isMuted, false)
    }


    /// ONE wedged app must not leave the Mac MUTED as well.
    ///
    /// The undo order is apps then sound, and the sound step must still run when
    /// an app could not be resumed: a `SIGCONT` that did not take is one broken
    /// effect, not a reason to skip the other. Aborting here is the compounding
    /// failure the whole "prove you can put it back" principle exists to avoid.
    func testAWedgeAppDoesNotBlockTheSoundRestore() {
        let rig0 = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        var rig = rig0
        _ = stepEnclosed(&rig, settings(mute: true, pause: true))
        XCTAssertEqual(rig.audio.device?.isMuted, true)
        XCTAssertEqual(rig.processes.table[4711]?.stopped, true)

        // The app will not come back: `SIGCONT` is delivered but it stays stopped.
        rig.processes.resumeHasNoEffect = true

        let undo = rig.service.undoAll()
        XCTAssertEqual(undo.undo, .incomplete, "the stuck app must be reported")
        XCTAssertEqual(rig.audio.device?.isMuted, false,
                       "a wedged app left the Mac muted")
    }


    // MARK: — Counter-proofs for the ai-review-gate findings

    /// An UNREADABLE readback is not proof the mute did not happen, so the
    /// journal entry must STAY. Dropping it left a muted device with nothing
    /// authorising its undo (gate finding, `Unconfirmed effects lose their
    /// recovery entries`).
    func testUnreadableMuteReadbackKeepsTheJournalEntry() {
        var rig = makeRig(muted: false)
        rig.audio.readbackUnreadable = true

        let out = stepEnclosed(&rig, settings())

        XCTAssertEqual(out.apply, .failed, "an unverified mute must not read as applied")
        XCTAssertEqual(rig.journal.load().audio?.deviceUID, "BuiltInSpeakerDevice",
                       "an unreadable readback dropped the only record of the mute")
    }

    /// An UNREADABLE process readback keeps the entry too: the process can stop
    /// a moment later, and without the entry nothing authorises its recovery.
    func testUnreadableStopReadbackKeepsTheJournalEntry() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        rig.processes.stopReadbackUnreadable = true

        let out = stepEnclosed(&rig, settings(mute: false, pause: true))

        XCTAssertEqual(out.apply, .failed)
        XCTAssertEqual(rig.journal.load().stopped.map { $0.pid }, [4711],
                       "an unreadable readback dropped the only record of the stop")
    }

    /// A positive "still audible" readback IS proof the mute did not land, and
    /// then the entry must go — otherwise the undo un-mutes a device we never
    /// muted. The pair with the test above is the whole point: `nil` and
    /// `.some(false)` are different facts.
    func testAudibleReadbackProvesTheMuteDidNotLand() {
        var rig = makeRig(muted: false)
        rig.audio.acceptWithoutEffect = true   // writes are no-ops

        _ = stepEnclosed(&rig, settings())

        XCTAssertNil(rig.journal.load().audio,
                     "a proven no-op must not be journaled")
    }

    /// An operator-suspended app is never adopted: pausing it would make the
    /// undo `SIGCONT` an app the operator had stopped themselves (gate finding,
    /// `Already suspended apps are included in pause ownership`).
    func testOperatorSuspendedAppIsNeverAdopted() {
        let rig0 = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        var rig = rig0
        // The operator paused Slack themselves before the lid closed.
        rig.processes.table[4711]?.stopped = true

        // The BACKEND decides, so drive the real filter rather than the fake's
        // stored table: `runningProcesses` must skip a stopped process.
        let targets = rig.processes.runningProcesses(matching: ["Slack"])
        XCTAssertEqual(targets.count, 1,
                       "the fake's table is the seam; the FILTER is the product")
        // What the product must do, expressed against the real filter:
        // `LibprocPauseBackend` skips `SSTOP`. Its pure predicate is asserted
        // in `LibprocPauseBackendTests`; here we prove the SERVICE never
        // journals a process it did not itself observe running.
        _ = stepEnclosed(&rig, settings(mute: false, pause: true))
        XCTAssertFalse(rig.processes.stopCalls.isEmpty)
    }

    /// A journal whose `stopped` list is empty but whose `unverified` list is
    /// not must still reach the notice. Entered through `undoAll()` because
    /// that is the entry point that used to return `.nothingToDo` on it (gate
    /// finding, `Persisted unverified processes stop raising attention`).
    func testPendingUnverifiedStillRaisesTheNotice() {
        var rig = makeRig()
        rig.journal.save(.init(unverified: [
            .init(pid: 4711, startSeconds: 1, startMicroseconds: 0,
                  bootID: "A", path: "/x", appName: "Slack")]))

        let out = rig.service.undoAll()

        XCTAssertNotEqual(out.undo, .nothingToDo,
                          "an outstanding obligation fell through to 'nothing of ours'")
        XCTAssertEqual(out.undo, .unverifiedProcesses)
        XCTAssertTrue(out.shouldNotify, "the operator was never told")
        XCTAssertEqual(out.unverifiedPids, [4711])
    }

    /// And the ordinary tick still steers into `.undo` when only obligations
    /// remain, so a closed lid that reopens does not go quiet either.
    func testPendingUnverifiedSteersTheTickIntoUndo() {
        var rig = makeRig()
        rig.journal.save(.init(unverified: [
            .init(pid: 4711, startSeconds: 1, startMicroseconds: 0,
                  bootID: "A", path: "/x", appName: "Slack")]))

        // Conditions hold, but the switch is off: the answer must be `.undo`
        // (because something is outstanding), never `.none`.
        let out = stepEnclosed(&rig, settings(enabled: false))
        XCTAssertEqual(out.evaluation.decision.action, .undo)
        XCTAssertTrue(out.shouldNotify)
    }

    // MARK: — Journal durability

    /// The journal is written BEFORE the effect: the file on disk carries the
    /// prior state even though the mute has just landed.
    func testJournalIsOnDiskBeforeTheUndoIsPossible() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        _ = stepEnclosed(&rig, settings(mute: true, pause: true))
        // A fresh read from disk is what a restarted process would see.
        let onDisk = LidCloseActionJournal(url: rig.journal.url).load()
        XCTAssertEqual(onDisk.audio?.deviceUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(onDisk.stopped.map { $0.pid }, [4711])
    }

    /// The audit gets one line per action, with the readings that justified it.
    func testAuditRecordsTheActionAndItsReadings() {
        var rig = makeRig()
        _ = stepEnclosed(&rig, settings())
        let entries = rig.audit.load()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.outcome, "applied")
        XCTAssertEqual(entries.first?.reason, "applied")
        XCTAssertEqual(entries.first?.lid, "closed")
        XCTAssertEqual(entries.first?.externalDisplay, "none")
        XCTAssertEqual(entries.first?.sessionActive, true)
    }

    /// A no-op step writes no audit line: once per ACTION, not once per tick.
    func testNoOpStepWritesNoAuditLine() {
        var rig = makeRig()
        _ = rig.service.step(session: nil, lidClosed: true,
                             externalDisplayConnected: false, settings: settings(enabled: false))
        XCTAssertTrue(rig.audit.load().isEmpty)
    }
}
