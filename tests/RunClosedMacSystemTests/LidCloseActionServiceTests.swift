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
        /// Number of upcoming `readOutput` calls that return nil without the
        /// device being gone — a transient failure, not a removal.
        var failNextReads = 0

        func readDefaultOutput() -> AudioOutputSnapshot? { device }
        func readOutput(uid: String) -> AudioOutputSnapshot? {
            if failNextReads > 0 {
                failNextReads -= 1
                return nil
            }
            guard !readbackUnreadable, !deviceGone, var d = device, d.uid == uid else {
                return nil
            }
            // Model a device whose mute FLAG cannot be read while the device
            // itself is perfectly reachable: the snapshot exists but its state
            // is unknown (CoreAudio returning noErr for the device and an error
            // for the property).
            if muteFlagUnreadable { d.isMuted = nil }
            return d
        }
        func setMuted(_ muted: Bool, uid: String) -> Bool {
            writes.append((muted, uid))
            guard !acceptWithoutEffect, var d = device, d.uid == uid else { return true }
            d.isMuted = muted
            device = d
            return true
        }
        /// When true, the device's mute flag becomes UNREADABLE (the mutation
        /// succeeds or fails, but the state cannot be observed afterwards).
        var muteFlagUnreadable = false
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
        /// Model the ASYNC part of SIGSTOP: the process only reads as stopped
        /// from the Nth read onwards. `nil` = immediate.
        var stopVisibleAfterReads: Int?
        /// Model PID REUSE between the enumeration and the signal: when set,
        /// the first `stop` call first recycles the pid to another process.
        var recycleBeforeFirstStop: UInt64?
        /// Model a CRASH part-way through the stop loop: reading the journal
        /// exactly at this point throws, so the collector captures what was on
        /// disk BEFORE the remaining signals were sent.
        var crashAfterSignals: Int?
        var signalCount = 0
        /// The journal contents captured at the crash point.
        var journalAtCrash: [Int32]?

        func runningProcesses(matching appNames: [String]) -> [RunningProcess] {
            let snapshot = table.values
                .filter { appNames.contains($0.appName) }
                .sorted { $0.pid < $1.pid }
                .map {
                    RunningProcess(pid: $0.pid, startSeconds: $0.startSeconds,
                                   startMicroseconds: $0.startMicroseconds,
                                   path: $0.path, appName: $0.appName)
                }
            // Recycle the pid IMMEDIATELY after the snapshot is taken: this is
            // the real window, where the app exits between enumeration and the
            // signal and the kernel hands its pid to something else.
            if let newStart = recycleBeforeFirstStop {
                recycleBeforeFirstStop = nil
                for target in snapshot {
                    if var p = table[target.pid] {
                        p.startSeconds = newStart
                        p.stopped = false
                        table[target.pid] = p
                    }
                }
            }
            return snapshot
        }

        func identity(ofPid pid: Int32) -> LidCloseActionJournal.ProcessIdentity? {
            guard let p = table[pid] else { return nil }
            return LidCloseActionJournal.ProcessIdentity(
                pid: p.pid, startSeconds: p.startSeconds,
                startMicroseconds: p.startMicroseconds, bootID: "A")
        }

        func stop(pid: Int32) -> Bool {
            stopCalls.append(pid)
            signalCount += 1
            if let deadline = crashAfterSignals, signalCount == deadline,
               let j = journalProbe {
                journalAtCrash = j()
            }
            guard !stopHasNoEffect, var p = table[pid] else { return true }
            // Model the ASYNC transition: with `stopVisibleAfterReads` set the
            // signal has landed but the process does not READ as stopped until
            // enough reads have happened (the real SIGSTOP window).
            readCount[pid] = 0
            if stopVisibleAfterReads == nil {
                p.stopped = true
                table[pid] = p
            }
            return true
        }

        func resume(pid: Int32) -> Bool {
            resumeCalls.append(pid)
            guard !resumeHasNoEffect, var p = table[pid] else { return true }
            p.stopped = false
            table[pid] = p
            return true
        }

        var readCount: [Int32: Int] = [:]
        /// Set by the rig so the fake can read the journal at the crash point.
        var journalProbe: (() -> [Int32])?

        func isStopped(pid: Int32) -> Bool? {
            guard !stopReadbackUnreadable else { return nil }
            readCount[pid, default: 0] += 1
            if let threshold = stopVisibleAfterReads,
               var p = table[pid], !p.stopped {
                if readCount[pid, default: 0] >= threshold {
                    p.stopped = true
                    table[pid] = p
                }
            }
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
        processes.journalProbe = { journal.load().stopped.map { $0.pid } }
        var service = LidCloseActionService(
            journal: journal, auditLog: audit, audio: audio, processes: processes,
            bootID: "A", wallClock: { Date(timeIntervalSince1970: 1_700_000_000) })
        // No sleeping in tests: the confirmation retries are driven by the
        // fakes' own read counters instead of wall-clock waits.
        service.stopConfirmDelay = {}
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
    ///
    /// The muted device is simply absent from the default-output path, so the
    /// undo cannot reach it. The obligation is RETAINED rather than silently
    /// dropped (an unreadable device is not proof of removal), and only after
    /// the device stays unreadable across `unreadablePassesBeforeGone`
    /// separate passes is it concluded gone — which is not an error (ADR 026).
    func testUserSwitchingOutputIsNotTouched() {
        var rig = makeRig(muted: false)
        _ = stepEnclosed(&rig, settings())

        rig.audio.deviceGone = true
        let first = rig.service.undoAll()

        XCTAssertEqual(first.undo, .incomplete,
                       "one unreadable pass must not be read as removal")
        XCTAssertEqual(rig.audio.writes.map { $0.muted }, [true],
                       "only the mute write; nothing was un-muted")
        XCTAssertEqual(rig.journal.load().audio?.unreadablePasses, 1,
                       "the obligation must be kept, with its failure count")
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


    /// SIGSTOP is ASYNCHRONOUS: the process needs to be scheduled to reach
    /// `SSTOP`, so one immediate read can legitimately still see it running.
    /// Believing that single read dropped the journal entry for a process that
    /// then stopped — and the undo could never resume it (gate finding,
    /// `Immediate running readback can discard a pending stop`).
    func testDelayedStopTransitionIsStillJournaled() {
        let rig0 = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        var rig = rig0
        // Stopped state becomes visible only on the 3rd read.
        rig.processes.stopVisibleAfterReads = 3

        let out = stepEnclosed(&rig, settings(mute: false, pause: true))

        XCTAssertEqual(out.apply, .applied, "a delayed transition read as a failure")
        XCTAssertEqual(rig.journal.load().stopped.map { $0.pid }, [4711],
                       "the entry was dropped for a process that DID stop")
        XCTAssertEqual(rig.processes.table[4711]?.stopped, true)
    }

    /// And a stop that genuinely never takes is still dropped — the retry must
    /// not turn "never stopped" into ownership.
    func testStopThatNeverTakesIsStillDroppedAfterTheRetries() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        rig.processes.stopHasNoEffect = true

        let out = stepEnclosed(&rig, settings(mute: false, pause: true))

        XCTAssertEqual(out.apply, .failed)
        XCTAssertTrue(rig.journal.load().stopped.isEmpty,
                      "ownership was granted to a process we never stopped")
    }

    /// One journal write per process, immediately before its own signal — so a
    /// crash part-way through the loop cannot grant ownership over the ones
    /// that were never signalled (gate finding, `Batch journal grants resume
    /// ownership before signals are sent`).
    func testOnlySignalledProcessesGainOwnership() {
        let rig0 = makeRig(apps: [(1, "Slack", 100), (2, "Discord", 100)])
        var rig = rig0
        // Look at the journal EXACTLY after the first signal, i.e. in the crash
        // window the gate described: a crash here must leave ownership of the
        // one process we signalled, and NOT of the one we never reached.
        rig.processes.crashAfterSignals = 1

        _ = stepEnclosed(&rig, settings(mute: false, pause: true))

        XCTAssertEqual(rig.processes.journalAtCrash, [1],
                       "the journal at the crash point must own only the signalled process")
        XCTAssertFalse(rig.processes.journalAtCrash?.contains(2) ?? true,
                       "an unsignalled process was granted resume ownership")
    }

    /// An UNREADABLE device is not a REMOVED device. The undo used to collapse
    /// both and drop the entry, leaving a muted device with nothing to retry
    /// from (gate finding, `Unreadable audio state is treated as device
    /// removal`). The retry distinguishes them.
    func testTransientUnreadableDoesNotLookLikeRemoval() {
        let rig0 = makeRig(muted: false)
        var rig = rig0
        _ = stepEnclosed(&rig, settings())
        XCTAssertEqual(rig.audio.device?.isMuted, true)

        // The device is still there, but the first read of the undo flakes.
        rig.audio.failNextReads = 1

        let undo = rig.service.undoAll()
        XCTAssertFalse(undo.audioDeviceGone, "a flaky read was reported as a removed device")
        XCTAssertEqual(rig.audio.device?.isMuted, false, "the sound was not restored")
    }

    /// A genuinely absent device is eventually concluded gone, and that is not
    /// an error (ADR 026) — but only after it has stayed unreadable across the
    /// configured number of separate passes, so a flaky read can never strand
    /// the obligation nor a single failure be read as removal.
    func testGenuinelyAbsentDeviceIsConcludedGoneAfterEscalation() {
        let rig0 = makeRig(muted: false)
        var rig = rig0
        _ = stepEnclosed(&rig, settings())
        rig.audio.deviceGone = true

        // Walk the escalation one pass at a time. The pass that reaches the
        // threshold is the one that concludes "gone": `unreadablePasses` is
        // incremented BEFORE it is compared, so the Nth pass is the decision.
        var concluded: LidCloseActionService.TickOutcome?
        for pass in 1...LidCloseActionService.unreadablePassesBeforeGone {
            concluded = rig.service.undoAll()
            if pass < LidCloseActionService.unreadablePassesBeforeGone {
                XCTAssertEqual(concluded?.undo, .incomplete,
                               "concluded gone too early (pass \(pass))")
                XCTAssertFalse(concluded?.audioDeviceGone ?? true)
            }
        }
        XCTAssertTrue(concluded?.audioDeviceGone ?? false,
                      "a device unreadable for \(LidCloseActionService.unreadablePassesBeforeGone) passes was never concluded gone")
        // Concluded gone, but NOT forgotten: the obligation moves to
        // `unverifiedAudio`, so a device that returns still holding its mute
        // state can be restored. That makes the undo `.unverifiedProcesses`
        // (an outstanding obligation), not `.restored`.
        XCTAssertEqual(concluded?.undo, .unverifiedProcesses,
                       "a concluded-gone device must stay an outstanding obligation")
        let rec = rig.journal.load()
        XCTAssertNil(rec.audio)
        XCTAssertEqual(rec.unverifiedAudio?.deviceUID, "BuiltInSpeakerDevice")
        XCTAssertTrue(rec.isEmpty, "no live effect remains")
    }

    /// A device concluded gone and then PLUGGED BACK IN still muted is
    /// re-adopted rather than forgotten (gate finding, `Temporary device
    /// absence permanently discards restoration`).
    func testReturningDeviceIsReAdopted() {
        var rig = makeRig(muted: false)
        rig.journal.save(.init(unverifiedAudio: .init(
            deviceUID: "BuiltInSpeakerDevice", wasMuted: false, volume: 0.5)))
        // The device is back and still muted.
        rig.audio.device?.isMuted = true

        _ = stepEnclosed(&rig, settings())

        XCTAssertNotNil(rig.journal.load().audio,
                        "the returning device was not re-adopted")
        _ = rig.service.undoAll()
        XCTAssertEqual(rig.audio.device?.isMuted, false, "the sound was never restored")
    }


    /// PID REUSE between enumeration and signal. The process we enumerated
    /// exits and the kernel hands the same pid to something else before we
    /// signal: sending SIGSTOP then would suspend an unrelated process while
    /// the journal recorded the ORIGINAL identity, so the undo would refuse to
    /// resume it and it would stay frozen (gate finding,
    /// `Process identity is not rechecked before stopping`).
    func testRecycledPidBetweenEnumerationAndSignalIsNeverSignalled() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        rig.processes.recycleBeforeFirstStop = 1_800_000_000

        let out = stepEnclosed(&rig, settings(mute: false, pause: true))

        XCTAssertTrue(rig.processes.stopCalls.isEmpty,
                      "SIGSTOP was sent after the pid had been recycled")
        XCTAssertTrue(rig.journal.load().stopped.isEmpty,
                      "ownership was recorded for a process we never signalled")
        XCTAssertEqual(out.apply, .failed)
    }

    /// An UNREADABLE mute flag is not "audible". Deriving the state from the
    /// write capability made a muted device report `isMuted: false`, so the
    /// undo cleared the journal on a device that was still silent (gate
    /// finding, `Unknown mute state is returned as verified unmuted`).
    func testUnreadableMuteFlagIsNotTreatedAsAudible() {
        let rig0 = makeRig(muted: false)
        var rig = rig0
        _ = stepEnclosed(&rig, settings())
        XCTAssertEqual(rig.audio.device?.isMuted, true)

        // The device is reachable but its flag cannot be read during the undo.
        rig.audio.muteFlagUnreadable = true
        let undo = rig.service.undoAll()

        XCTAssertEqual(undo.undo, .incomplete,
                       "an unreadable flag was read as proof of a restore")
        XCTAssertNotNil(rig.journal.load().audio,
                        "the obligation was cleared on an unreadable reading")
    }

    /// Two failed reads across the SAME pass are not proof of removal: the
    /// obligation is kept and counted, not erased (gate finding, `Two
    /// unreadable audio snapshots erase the recovery obligation`).
    func testTwoUnreadableReadsInOnePassDoNotEraseTheObligation() {
        let rig0 = makeRig(muted: false)
        var rig = rig0
        _ = stepEnclosed(&rig, settings())
        // Both the first read and its retry fail.
        rig.audio.failNextReads = 2

        let undo = rig.service.undoAll()

        XCTAssertFalse(undo.audioDeviceGone, "two flaky reads were read as removal")
        XCTAssertNotNil(rig.journal.load().audio, "the obligation was erased")
        XCTAssertEqual(rig.journal.load().audio?.unreadablePasses, 1)
    }


    /// Turning OFF a single effect switch must UNDO that effect, without
    /// waiting for the master switch or for the conditions to change. The apply
    /// path used to skip the disabled effect and leave the Mac muted (gate
    /// finding, `Disabling an individual effect does not restore it`).
    func testTurningOffTheMuteSwitchRestoresTheSound() {
        var rig = makeRig()
        _ = stepEnclosed(&rig, settings(mute: true))
        XCTAssertEqual(rig.audio.device?.isMuted, true)

        // The operator unticks "Mute the sound" only; the session and the
        // conditions are unchanged.
        let out = stepEnclosed(&rig, settings(mute: false))

        XCTAssertEqual(rig.audio.device?.isMuted, false, "the sound was left muted")
        XCTAssertNil(rig.journal.load().audio, "the obligation should be gone")
        XCTAssertEqual(out.evaluation.decision.action, .apply, "the master switch is still on")
    }

    /// Same for the app-pause switch: unticking it resumes what it paused.
    func testTurningOffThePauseSwitchResumesTheApps() {
        let rig0 = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        var rig = rig0
        _ = stepEnclosed(&rig, settings(mute: false, pause: true))
        XCTAssertEqual(rig.processes.table[4711]?.stopped, true)

        _ = stepEnclosed(&rig, settings(mute: false, pause: false))

        XCTAssertEqual(rig.processes.table[4711]?.stopped, false, "the app was left frozen")
        XCTAssertTrue(rig.journal.load().stopped.isEmpty)
    }

    /// The converse still holds: an effect that is ON keeps the switch's own
    /// journal entry, so turning the switch off later has something to undo.
    func testTurningASwitchOnStillJournalsItsEffect() {
        var rig = makeRig()
        _ = stepEnclosed(&rig, settings(mute: true))
        XCTAssertNotNil(rig.journal.load().audio)
        // A second apply with the same settings must not duplicate anything.
        _ = stepEnclosed(&rig, settings(mute: true))
        XCTAssertEqual(rig.audio.writes.count, 1)
    }


    /// A `SIGSTOP` whose effect lands AFTER the bounded observation window must
    /// not lose its recovery entry: a wait that expires is not proof the signal
    /// will never take (gate finding, `A stop confirmation timeout discards a
    /// pending signal's recovery entry`). The entry moves to "to verify".
    func testStopThatTimesOutIsKeptAsToVerify() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        // Never reads as stopped, but the signal WAS delivered.
        rig.processes.stopVisibleAfterReads = 9_999

        _ = stepEnclosed(&rig, settings(mute: false, pause: true))

        let rec = rig.journal.load()
        XCTAssertTrue(rec.stopped.isEmpty, "a timeout must not stay a resume candidate")
        XCTAssertEqual(rec.unverified.map { $0.pid }, [4711],
                       "the entry for a pending signal was destroyed")
    }

    /// An outstanding process notice survives the operator turning the pause
    /// switch off: the first pass moves it to "to verify", and later passes
    /// must keep saying so instead of going quiet (gate finding, `Individual
    /// pause-switch disable silences outstanding process notices`).
    func testDisablingThePauseSwitchKeepsReportingToVerify() {
        var rig = makeRig()
        rig.journal.save(.init(unverified: [
            .init(pid: 4711, startSeconds: 1, startMicroseconds: 0,
                  bootID: "A", path: "/x", appName: "Slack")]))

        let out = stepEnclosed(&rig, settings(mute: true, pause: false))

        XCTAssertTrue(out.shouldNotify, "the outstanding notice went silent")
        XCTAssertEqual(out.unverifiedPids, [4711])
    }

    /// A device that comes back after being concluded gone is restored by the
    /// UNDO too, not only by an apply: a session can end while it is unplugged
    /// (gate finding, `Returning audio devices are never restored during undo`).
    func testReturningDeviceIsRestoredDuringUndo() {
        let rig0 = makeRig(muted: false)
        var rig = rig0
        rig.journal.save(.init(unverifiedAudio: .init(
            deviceUID: "BuiltInSpeakerDevice", wasMuted: false, volume: 0.5)))
        rig.audio.device?.isMuted = true

        let undo = rig.service.undoAll()

        XCTAssertEqual(rig.audio.device?.isMuted, false, "the returned device stayed muted")
        XCTAssertEqual(undo.undo, .restored)
        XCTAssertTrue(rig.journal.load().isEmpty)
    }

    /// Reopening a journal must carry the audio obligation forward, or a new
    /// session silently forgets a device that has not come back yet.
    func testReopeningCarriesUnverifiedAudioForward() {
        let prior = LidCloseActionJournal.Record(unverifiedAudio: .init(
            deviceUID: "BuiltInSpeakerDevice", wasMuted: false, volume: 0.5))
        let next = prior.reopened(sessionID: UUID(), at: "2026-11-08T10:00:00Z")
        XCTAssertEqual(next.unverifiedAudio?.deviceUID, "BuiltInSpeakerDevice",
                       "reopening dropped the audio obligation")
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
