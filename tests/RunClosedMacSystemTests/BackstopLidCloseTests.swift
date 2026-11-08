import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// The ADR 024 backstop running the ADR 026 lid-close actions.
///
/// The point of these tests is the one sentence the plan insists on: the
/// backstop applies the SAME policy, not a copy. A Mac whose app crashed must
/// not stay muted with an app frozen, and the proof is that the same
/// `LidCloseActionPolicy` decides here as in the app's tick.
final class BackstopLidCloseTests: XCTestCase {

    // MARK: — Fakes (deliberately small: this file tests the WIRING)

    private final class FakeLid: LidAssertion, @unchecked Sendable {
        var calls: [Bool] = []
        let flag: FlagBox
        init(flag: FlagBox) { self.flag = flag }
        func setEnabled(_ enabled: Bool) -> OperationResult {
            calls.append(enabled)
            flag.value = enabled
            return OperationResult(requestID: "t", action: .sleepAll, state: .verified,
                                   nativeRC: 0, readbackOK: true)
        }
    }

    private final class FlagBox: @unchecked Sendable {
        var value: Bool?
        init(_ v: Bool?) { value = v }
    }

    private final class FakeSleeper: SystemSleeper, @unchecked Sendable {
        func sleepNow() -> (rc: Int32, output: String?) { (0, nil) }
    }

    private final class ClockBox: ContinuousClock, @unchecked Sendable {
        var wall: Date
        var continuous: UInt64
        let bootID: String
        init(wall: Date, continuous seconds: Double, bootID: String) {
            self.wall = wall
            self.continuous = ContinuousClockTimebase.nanoseconds(fromSeconds: seconds)
            self.bootID = bootID
        }
        var nowContinuousNanoseconds: UInt64 { continuous }
    }

    private final class FakeAudio: AudioOutputBackend, @unchecked Sendable {
        var device: AudioOutputSnapshot?
        var writes: [(muted: Bool, uid: String)] = []
        var deviceGone = false
        func readDefaultOutput() -> AudioOutputSnapshot? { device }
        func readOutput(uid: String) -> AudioOutputSnapshot? {
            guard !deviceGone, let d = device, d.uid == uid else { return nil }
            return d
        }
        func setMuted(_ muted: Bool, uid: String) -> Bool {
            writes.append((muted, uid))
            guard !deviceGone, var d = device, d.uid == uid else { return true }
            d.isMuted = muted
            device = d
            return true
        }
    }

    private final class FakeProcesses: ProcessPauseBackend, @unchecked Sendable {
        struct P {
            var pid: Int32
            var start: UInt64
            var path: String
            var name: String
            var stopped = false
        }
        var table: [Int32: P] = [:]
        var resumeCalls: [Int32] = []

        func runningProcesses(matching appNames: [String]) -> [RunningProcess] {
            table.values.filter { appNames.contains($0.name) }
                .sorted { $0.pid < $1.pid }
                .map { RunningProcess(pid: $0.pid, startSeconds: $0.start,
                                      startMicroseconds: 0, path: $0.path, appName: $0.name) }
        }
        func identity(ofPid pid: Int32) -> LidCloseActionJournal.ProcessIdentity? {
            guard let p = table[pid] else { return nil }
            return .init(pid: p.pid, startSeconds: p.start, startMicroseconds: 0, bootID: "A")
        }
        func stop(pid: Int32) -> Bool {
            guard var p = table[pid] else { return true }
            p.stopped = true
            table[pid] = p
            return true
        }
        func resume(pid: Int32) -> Bool {
            resumeCalls.append(pid)
            guard var p = table[pid] else { return true }
            p.stopped = false
            table[pid] = p
            return true
        }
        func isStopped(pid: Int32) -> Bool? { table[pid]?.stopped }
    }

    private final class SettingsBox: @unchecked Sendable {
        var settings: LidCloseActionSettings
        init(_ s: LidCloseActionSettings) { settings = s }
    }

    private struct Rig {
        var service: RecoveryBackstopService
        let flag: FlagBox
        let sessionStore: SessionStore
        let lidStore: OwnedLidAssertion
        let audio: FakeAudio
        let processes: FakeProcesses
        let journal: LidCloseActionJournal
        let settings: SettingsBox
        let recoveryAudit: RecoveryAuditLog
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRig(flag: Bool? = true,
                         ownedBoot: String? = "A",
                         settings: LidCloseActionSettings =
                            LidCloseActionSettings(enabled: true, muteAudio: true,
                                                   pauseApps: true),
                         apps: [(pid: Int32, name: String, start: UInt64)] = [],
                         audioMuted: Bool = false) -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-backstop-lid-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let lidStore = OwnedLidAssertion(currentBootID: "A",
                                         url: dir.appendingPathComponent("owned_lid.json"))
        if let b = ownedBoot {
            lidStore.save(.init(bootID: b, ownedEnabled: true, referenceState: "on"))
        }
        let sessionStore = SessionStore(url: dir.appendingPathComponent("session.json"))
        let latchStore = LowBatteryLatchStore(url: dir.appendingPathComponent("latch.json"))
        let flagBox = FlagBox(flag)
        let lid = FakeLid(flag: flagBox)
        let clock = ClockBox(wall: epoch, continuous: 1_000, bootID: "A")
        let lockURL = dir.appendingPathComponent("lid.lock")

        let sessionService = SessionService(
            store: sessionStore, latchStore: latchStore, continuous: clock,
            wallClock: { clock.wall }, observedFlag: { flagBox.value },
            ownershipRecord: {
                let rec = lidStore.load()
                return (rec.bootID, rec.ownedEnabled)
            },
            applyLid: SessionService.gatedLid(
                bootID: "A", makeMutator: { lid }, store: lidStore,
                priorProvider: { flagBox.value }))

        let audio = FakeAudio()
        audio.device = AudioOutputSnapshot(uid: "BuiltInSpeakerDevice", isMuted: audioMuted,
                                           volume: 0.5, canMute: true)
        let processes = FakeProcesses()
        for app in apps {
            processes.table[app.pid] = .init(
                pid: app.pid, start: app.start,
                path: "/Applications/\(app.name).app/Contents/MacOS/\(app.name)",
                name: app.name)
        }
        let journal = LidCloseActionJournal(url: dir.appendingPathComponent("lid_close_actions.json"))
        let settingsBox = SettingsBox(settings)
        let lidCloseService = LidCloseActionService(
            journal: journal,
            auditLog: LidCloseActionAuditLog(url: dir.appendingPathComponent("lid_close_audit.jsonl")),
            audio: audio, processes: processes, bootID: "A",
            wallClock: { clock.wall })

        var guardService = LowBatteryGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: latchStore,
            // A healthy battery at 60 %: nothing the battery step wants to do,
            // so whatever happens here is the lid-close step's doing.
            batteryProvider: {
                BatteryState(onBattery: false, chargePercent: 60, minutesRemaining: nil,
                             isCharging: true, batteryPresent: true)
            },
            sleeper: FakeSleeper(),
            lock: LidWriteLock(url: lockURL),
            auditLog: LowBatteryAuditLog(url: dir.appendingPathComponent("low_battery_audit.jsonl")),
            sessionService: sessionService,
            lidCloseActions: lidCloseService,
            // The lid is closed and no display is attached: the three
            // conditions hold, which is what makes the APPLY reachable.
            lidCloseReadings: {
                LidCloseActionService.Readings(session: nil, lidClosed: true,
                                               externalDisplayConnected: false,
                                               settings: settingsBox.settings)
            })

        let recoveryAudit = RecoveryAuditLog(
            url: dir.appendingPathComponent("recovery_audit.jsonl"))
        let service = RecoveryBackstopService(
            sessionService: sessionService,
            guardService: guardService,
            lock: LidWriteLock(url: lockURL),
            auditLog: recoveryAudit,
            heartbeatStore: BackstopHeartbeatStore(
                url: dir.appendingPathComponent("backstop_heartbeat.json")),
            appIsAlive: { false },
            batteryGuardEnabled: { true },
            thermalGuardEnabled: { false },
            // The SAME journal the lid-close service writes.
            lidCloseJournal: journal,
            wallClock: { clock.wall })

        return Rig(service: service, flag: flagBox, sessionStore: sessionStore,
                   lidStore: lidStore, audio: audio, processes: processes,
                   journal: journal, settings: settingsBox, recoveryAudit: recoveryAudit)
    }

    /// The recovery audit's lid-close lines, for the once-per-action assertions.
    private func lidCloseAuditLines(_ rig: Rig) -> [RecoveryAuditLog.Entry] {
        rig.recoveryAudit.load().filter { $0.step == "lidCloseActions" }
    }

    private func saveIndefiniteSession(_ rig: Rig) {
        // No end time: the plan's "a session is in progress", not "a timed
        // session".
        rig.sessionStore.save(KeepAwakeSession(startedAt: epoch, bootID: "A"))
    }


    /// The FAST PATH must take the lock when only OBLIGATIONS remain: a record
    /// holding `unverified` processes or a stranded device is not `isEmpty`, but
    /// it still needs the backstop (gate finding, `Recovery fast path ignores
    /// unverified obligations`).
    func testFastPathHonoursAJournalOfObligationsOnly() {
        var rig = makeRig(flag: nil, ownedBoot: nil)
        rig.journal.save(.init(unverified: [
            .init(pid: 4711, startSeconds: 1, startMicroseconds: 0,
                  bootID: "A", path: "/x", appName: "Slack")]))

        let outcome = rig.service.run()

        XCTAssertNotEqual(outcome, .nothingToDo,
                          "an outstanding obligation took the fast path")
    }

    /// And a stranded audio device counts the same way.
    func testFastPathHonoursAStrandedDevice() {
        var rig = makeRig(flag: nil, ownedBoot: nil)
        rig.journal.save(.init(unverifiedAudio: [.init(
            deviceUID: "BuiltInSpeakerDevice", wasMuted: false, volume: 0.5)]))

        let outcome = rig.service.run()

        XCTAssertNotEqual(outcome, .nothingToDo,
                          "a stranded audio obligation took the fast path")
    }

    // MARK: — Apply

    /// A live session with the lid closed applies the actions through the same
    /// policy the app runs.
    func testBackstopAppliesTheActionsWhenTheConditionsHold() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        saveIndefiniteSession(rig)

        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertTrue(report.lidCloseStepRan)
        XCTAssertEqual(report.lidClose?.evaluation.decision.action, .apply)
        XCTAssertEqual(rig.audio.device?.isMuted, true)
        XCTAssertEqual(rig.processes.table[4711]?.stopped, true)
        XCTAssertFalse(rig.journal.load().isEmpty)
    }

    /// The switch off means no apply — but the journal is still read, so a
    /// leftover from a previous session would still be undone.
    func testBackstopDoesNotApplyWithTheSwitchOff() {
        var rig = makeRig(settings: LidCloseActionSettings(enabled: false))
        saveIndefiniteSession(rig)

        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.lidClose?.evaluation.decision.reason, .switchedOff)
        XCTAssertTrue(rig.audio.writes.isEmpty)
    }

    // MARK: — Undo, the reason this step is in the backstop at all

    /// THE case the plan names: the app crashed with a journal on disk. The
    /// backstop must undo it, with no session and no operator.
    func testBackstopUndoesACrashedSessionsActions() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        // The state a crashed app leaves: the journal names the effects, the
        // device is muted and the app is stopped, and there is NO session.
        rig.journal.save(.init(
            audio: [.init(deviceUID: "BuiltInSpeakerDevice", wasMuted: false, volume: 0.5)],
            stopped: [.init(pid: 4711, startSeconds: 1_700_000_000, startMicroseconds: 0,
                            bootID: "A", path: "/Applications/Slack.app/Contents/MacOS/Slack",
                            appName: "Slack")]))
        rig.audio.device?.isMuted = true
        rig.processes.table[4711]?.stopped = true

        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.lidClose?.undo, .restored)
        XCTAssertEqual(rig.processes.table[4711]?.stopped, false, "a frozen app was left frozen")
        XCTAssertEqual(rig.audio.device?.isMuted, false, "the Mac was left muted")
        XCTAssertTrue(rig.journal.load().isEmpty)
    }

    /// The journal alone is a reason to take the lock: with no session and no
    /// owning record, the fast path must NOT skip the undo.
    func testJournalAloneIsAReasonToWork() {
        var rig = makeRig(flag: nil, ownedBoot: nil)
        rig.journal.save(.init(audio: [.init(deviceUID: "BuiltInSpeakerDevice",
                                            wasMuted: false, volume: 0.5)]))
        rig.audio.device?.isMuted = true

        let outcome = rig.service.run()
        guard case .completed = outcome else {
            return XCTFail("the fast path skipped a pending undo: \(outcome)")
        }
        XCTAssertEqual(rig.audio.device?.isMuted, false)
    }

    /// And with an empty journal and nothing to protect, the minute stays free.
    func testEmptyJournalKeepsTheFastPathFree() {
        var rig = makeRig(flag: nil, ownedBoot: nil)
        let outcome = rig.service.run()
        XCTAssertEqual(outcome, .nothingToDo)
        XCTAssertTrue(rig.audio.writes.isEmpty)
    }

    /// The undo is the same policy, not a copy: a recycled pid is refused here
    /// exactly as it is in the app.
    func testBackstopRefusesARecycledPid() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_999)])
        rig.journal.save(.init(
            stopped: [.init(pid: 4711, startSeconds: 1_700_000_000, startMicroseconds: 0,
                            bootID: "A", path: "/Applications/Slack.app/Contents/MacOS/Slack",
                            appName: "Slack")]))
        rig.processes.table[4711]?.stopped = true

        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.lidClose?.undo, .unverifiedProcesses)
        XCTAssertTrue(rig.processes.resumeCalls.isEmpty, "a recycled pid was resumed")
        XCTAssertEqual(report.lidClose?.unverifiedPids, [4711])
    }

    /// A new session that appears while a journal is pending does not erase the
    /// "to verify" list: the obligation survives the episode.
    func testUnverifiedSurvivesANewEpisode() {
        var rig = makeRig(apps: [(4711, "Slack", 1_700_000_000)])
        rig.journal.save(.init(
            stopped: [.init(pid: 4711, startSeconds: 1_700_000_000, startMicroseconds: 0,
                            bootID: "A", path: "/Applications/Slack.app/Contents/MacOS/Slack",
                            appName: "Slack")]))
        // The pid now belongs to something else.
        rig.processes.table[4711]?.start = 1_800_000_000

        _ = rig.service.run()
        XCTAssertEqual(rig.journal.load().unverified.map { $0.pid }, [4711])

        // A new session starts and the conditions hold again: the unverified
        // entry must still be there afterwards.
        saveIndefiniteSession(rig)
        _ = rig.service.run()
        XCTAssertEqual(rig.journal.load().unverified.map { $0.pid }, [4711],
                       "a new episode erased an obligation the operator was never told about")
    }

    // MARK: — Reporting

    /// The JSON the agent prints carries the lid-close fields when — and only
    /// when — the step ran, so a machine that never used the feature keeps the
    /// older report byte for byte.
    func testDescribeCarriesTheLidCloseFieldsOnlyWhenTheStepRan() {
        var rig = makeRig()
        saveIndefiniteSession(rig)
        let outcome = rig.service.run()
        let (json, _) = RecoveryBackstopService.describe(outcome, bootID: "A")
        XCTAssertEqual(json["lidCloseStepRan"] as? Bool, true)
        XCTAssertEqual(json["lidCloseReason"] as? String, "applied")
        XCTAssertNotNil(json["lidCloseApply"])
        XCTAssertNotNil(json["lidCloseStoppedPids"])
    }

    /// A minute that never reached the step says nothing about it.
    func testDescribeOmitsTheFieldsOnTheFastPath() {
        var rig = makeRig(flag: nil, ownedBoot: nil)
        let outcome = rig.service.run()
        let (json, _) = RecoveryBackstopService.describe(outcome, bootID: "A")
        XCTAssertNil(json["lidCloseStepRan"])
        XCTAssertNil(json["lidCloseReason"])
    }

    /// A minute that DID something writes an audit line; a no-op minute does not
    /// (the once-per-action rule).
    func testAuditLineOnlyWhenSomethingHappened() {
        var rig = makeRig()
        saveIndefiniteSession(rig)
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertTrue(report.audited)
        XCTAssertEqual(lidCloseAuditLines(rig).count, 1)
    }

    /// The refusal path writes nothing: an operator who switched the feature off
    /// must not get a lid-close audit line every 60 s.
    func testNoAuditLineWhenTheStepDidNothing() {
        var rig = makeRig(settings: LidCloseActionSettings(enabled: false))
        saveIndefiniteSession(rig)
        _ = rig.service.run()
        XCTAssertTrue(lidCloseAuditLines(rig).isEmpty)
    }
}
