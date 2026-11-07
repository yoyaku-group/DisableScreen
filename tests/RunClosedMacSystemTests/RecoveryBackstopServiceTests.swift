import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// The ADR 024 backstop, driven end to end on fakes: a fake lid, a fake
/// sleeper, temp-dir stores and a controllable liveness probe. Nothing here
/// touches the real power flag, and no test registers anything.
final class RecoveryBackstopServiceTests: XCTestCase {

    // MARK: — Fakes

    private final class FakeLid: LidAssertion, @unchecked Sendable {
        var calls: [Bool] = []
        var failWrites = false
        let flag: FlagBox
        init(flag: FlagBox) { self.flag = flag }
        func setEnabled(_ enabled: Bool) -> OperationResult {
            calls.append(enabled)
            if failWrites {
                return OperationResult(requestID: "t", action: .sleepAll, state: .failed,
                                       nativeRC: 1, readbackOK: false,
                                       error: "sudo: a password is required")
            }
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
        var count = 0
        func sleepNow() -> (rc: Int32, output: String?) {
            count += 1
            return (0, nil)
        }
    }

    private final class ClockBox: ContinuousClock, @unchecked Sendable {
        var wall: Date
        var continuous: UInt64
        let bootID: String
        init(wall: Date, continuous seconds: Double, bootID: String = "A") {
            self.wall = wall
            self.continuous = ContinuousClockTimebase.nanoseconds(fromSeconds: seconds)
            self.bootID = bootID
        }
        var nowContinuousNanoseconds: UInt64 { continuous }
        func advance(_ seconds: TimeInterval) {
            wall = wall.addingTimeInterval(seconds)
            continuous += ContinuousClockTimebase.nanoseconds(fromSeconds: seconds)
        }
    }

    private final class BatteryBox: @unchecked Sendable {
        var state: BatteryState
        init(_ s: BatteryState) { state = s }
    }

    private final class AliveBox: @unchecked Sendable {
        var alive = false
    }

    private struct Rig {
        var service: RecoveryBackstopService
        let lid: FakeLid
        let sleeper: FakeSleeper
        let flag: FlagBox
        let clock: ClockBox
        let sessionStore: SessionStore
        let latchStore: LowBatteryLatchStore
        let lidStore: OwnedLidAssertion
        let battery: BatteryBox
        let alive: AliveBox
        let lockURL: URL
        let auditLog: RecoveryAuditLog
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private static func reading(_ onBattery: Bool?, _ pct: Int?, _ minutes: Int? = nil) -> BatteryState {
        BatteryState(onBattery: onBattery, chargePercent: pct, minutesRemaining: minutes,
                     isCharging: onBattery == false, batteryPresent: true)
    }

    /// `ownedBoot`: which boot wrote a claiming record (`nil` = no record).
    private func makeRig(flag: Bool?,
                         ownedBoot: String?,
                         battery: BatteryState,
                         appAlive: Bool = false,
                         bootID: String = "A") -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-backstop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lidStore = OwnedLidAssertion(currentBootID: bootID,
                                         url: dir.appendingPathComponent("owned_lid.json"))
        if let b = ownedBoot {
            lidStore.save(.init(bootID: b, ownedEnabled: true, referenceState: "on"))
        }
        let sessionStore = SessionStore(url: dir.appendingPathComponent("session.json"))
        let latchStore = LowBatteryLatchStore(url: dir.appendingPathComponent("latch.json"))
        let flagBox = FlagBox(flag)
        let lid = FakeLid(flag: flagBox)
        let sleeper = FakeSleeper()
        let batteryBox = BatteryBox(battery)
        let clock = ClockBox(wall: epoch, continuous: 1_000, bootID: bootID)
        let aliveBox = AliveBox()
        aliveBox.alive = appAlive
        let lockURL = dir.appendingPathComponent("lid.lock")
        let auditLog = RecoveryAuditLog(url: dir.appendingPathComponent("recovery_audit.jsonl"))

        let apply = SessionService.gatedLid(
            bootID: bootID, makeMutator: { lid }, store: lidStore,
            priorProvider: { flagBox.value })
        let sessionService = SessionService(
            store: sessionStore, latchStore: latchStore, continuous: clock,
            wallClock: { clock.wall }, observedFlag: { flagBox.value },
            ownershipRecord: {
                let rec = lidStore.load()
                return (rec.bootID, rec.ownedEnabled)
            },
            applyLid: apply)
        let guardService = LowBatteryGuardService(
            lidService: LidMutationService(bootID: bootID, mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: latchStore,
            batteryProvider: { batteryBox.state },
            sleeper: sleeper,
            lock: LidWriteLock(url: lockURL),
            auditLog: LowBatteryAuditLog(url: dir.appendingPathComponent("low_battery_audit.jsonl")),
            // The real wiring: a critical-battery release pauses the session
            // rather than orphaning it (ADR 023 §4).
            sessionService: sessionService)
        let service = RecoveryBackstopService(
            sessionService: sessionService,
            guardService: guardService,
            lock: LidWriteLock(url: lockURL),
            auditLog: auditLog,
            appIsAlive: { aliveBox.alive },
            wallClock: { clock.wall })

        return Rig(service: service, lid: lid, sleeper: sleeper, flag: flagBox, clock: clock,
                   sessionStore: sessionStore, latchStore: latchStore, lidStore: lidStore,
                   battery: batteryBox, alive: aliveBox, lockURL: lockURL, auditLog: auditLog)
    }

    private func saveSession(_ rig: Rig,
                             duration: TimeInterval? = 2 * 3600,
                             bootID: String = "A",
                             continuousStart: Double = 1_000,
                             paused: SessionPauseReason? = nil) {
        rig.sessionStore.save(KeepAwakeSession(
            startedAt: epoch,
            endsAtWall: duration.map { epoch.addingTimeInterval($0) },
            endsAtContinuous: duration.map {
                ContinuousClockTimebase.nanoseconds(fromSeconds: continuousStart + $0)
            },
            bootID: bootID,
            pausedReason: paused))
    }

    // MARK: — Fast path and liveness

    /// No record, no session: a no-op minute, and NO `pmset` call at all.
    func testNoRecordAndNoSessionExitsWithoutTouchingPmset() {
        var rig = makeRig(flag: nil, ownedBoot: nil, battery: Self.reading(false, 60))
        let outcome = rig.service.run()
        XCTAssertEqual(outcome, .nothingToDo)
        XCTAssertEqual(outcome.exitCode, .ok)
        XCTAssertTrue(rig.lid.calls.isEmpty, "the fast path must not call pmset")
        XCTAssertTrue(rig.auditLog.load().isEmpty, "and must not write an audit line")
    }

    /// The app is running: it is in charge, so the backstop does nothing — and
    /// takes no lock (the lock probe below proves it by taking it right after).
    func testAppAliveDoesNothingAndTakesNoLock() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 5),
                          appAlive: true)
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)
        let outcome = rig.service.run()
        XCTAssertEqual(outcome, .appAlive)
        XCTAssertEqual(outcome.exitCode, .ok)
        XCTAssertTrue(rig.lid.calls.isEmpty, "no mutation while the app enforces")
        XCTAssertEqual(rig.sleeper.count, 0)
        XCTAssertNotNil(rig.sessionStore.load(), "the session is untouched")
        // Nothing was left held: a non-blocking acquisition succeeds.
        XCTAssertEqual(LidWriteLock(url: rig.lockURL).tryWithLock { 1 }, 1)
    }

    /// Another writer holds `LidWriteLock`: exit 75 and no mutation. The lock is
    /// taken NON-BLOCKING — proved by holding it on another fd for the whole
    /// call and still getting an answer.
    func testBusyLockReturns75WithoutMutation() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 5))
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)

        let other = LidWriteLock(url: rig.lockURL)
        let held = other.tryWithLock { () -> Int in
            // Inside the held section, the backstop must return at once.
            let outcome = rig.service.run()
            XCTAssertEqual(outcome, .busy)
            XCTAssertEqual(outcome.exitCode, .busy)
            XCTAssertEqual(outcome.exitCode.rawValue, 75)
            return 1
        }
        XCTAssertEqual(held, 1, "the backstop must return while the lock is held, not block")
        XCTAssertTrue(rig.lid.calls.isEmpty, "a busy minute mutates nothing")
        XCTAssertEqual(rig.sleeper.count, 0)
        XCTAssertNotNil(rig.sessionStore.load())
        XCTAssertTrue(rig.auditLog.load().isEmpty, "a busy minute is not audited")

        // And once the lock is free the very next minute does the work.
        rig.clock.advance(60)
        let outcome = rig.service.run()
        XCTAssertEqual(outcome.exitCode, .ok)
        XCTAssertEqual(rig.flag.value, false)
    }

    // MARK: — Session step

    /// A session that came due while the app was closed is released and
    /// cleared, and the readback is what decides the outcome.
    func testDueSessionIsReleasedAndCleared() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60))
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.session?.expiry, .ended(.released))
        XCTAssertEqual(outcome.exitCode, .ok)
        XCTAssertEqual(rig.lid.calls, [false], "the release is the only write")
        XCTAssertNil(rig.sessionStore.load())
        XCTAssertEqual(rig.flag.value, false)
        let lines = rig.auditLog.load()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.step, "sessionExpiry")
        XCTAssertEqual(lines.first?.outcome, "released")
        XCTAssertEqual(lines.first?.reason, "deadlinePassed")
    }

    /// A running session that is not due is a NO-OP minute: no mutation, no
    /// audit line (the 60 s cadence must not flood the log).
    func testRunningSessionIsANoopWithoutAnAuditLine() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60))
        saveSession(rig, duration: 8 * 3600)
        let outcome = rig.service.run()
        XCTAssertEqual(outcome.exitCode, .ok)
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertTrue(rig.auditLog.load().isEmpty, "no-op minutes are never logged")
        XCTAssertNotNil(rig.sessionStore.load())
    }

    /// Our own record from a PREVIOUS boot, plus the session that record backs:
    /// released through `.sessionRecovery(bootID:)`, which the gate admits
    /// because the record's boot matches the session's boot.
    func testPreviousBootOwnRecordWithMatchingSessionIsReleasedAsSessionRecovery() {
        var rig = makeRig(flag: true, ownedBoot: "OLD", battery: Self.reading(false, 60))
        saveSession(rig, duration: 3_600, bootID: "OLD", continuousStart: 1_000)
        // The deadline is read from the WALL clock here: the session's
        // continuous counter belongs to another boot.
        rig.clock.advance(2 * 3_600)
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.session?.expiry, .ended(.released))
        XCTAssertEqual(rig.lid.calls, [false])
        XCTAssertNil(rig.sessionStore.load())
        XCTAssertEqual(rig.flag.value, false)
    }

    /// A record from another boot with NO matching session: `.automatic` still
    /// refuses it (ADR 015), so the backstop must not release the flag. This is
    /// the B2 boundary the lot must not widen.
    func testForeignRecordWithoutAMatchingSessionIsRefused() {
        var rig = makeRig(flag: true, ownedBoot: "SOMEONE-ELSE", battery: Self.reading(false, 60))
        saveSession(rig, duration: 60, bootID: "A")
        rig.clock.advance(3_600)
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        // The session's own boot is A (this boot), so `.automatic` runs and the
        // record claims another boot entirely: notOwned, flag left on.
        XCTAssertEqual(report.session?.expiry, .ended(.flagLeftOn))
        XCTAssertTrue(rig.lid.calls.isEmpty, "B2: no write on a foreign record")
        XCTAssertEqual(rig.flag.value, true)
        XCTAssertNil(rig.sessionStore.load(), "the record still goes: nothing enforces it")
        XCTAssertEqual(outcome.exitCode, .ok)
    }

    /// The release failed (the write did not verify): the record is RETAINED,
    /// the run reports a backend failure, and the audit line says so.
    func testFailedReleaseRetainsTheRecordAndExits5() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60))
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)
        rig.lid.failWrites = true
        let outcome = rig.service.run()
        XCTAssertEqual(outcome.exitCode, .backendFailure)
        XCTAssertEqual(outcome.exitCode.rawValue, 5)
        XCTAssertNotNil(rig.sessionStore.load(), "a failed release is never a finished session")
        let lines = rig.auditLog.load()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.outcome, "retained")
        XCTAssertNotNil(lines.first?.error)
    }

    /// An orphan — a running session over a flag that reads OFF — is reconciled
    /// without a write.
    func testOrphanSessionIsClearedWithoutMutation() {
        var rig = makeRig(flag: false, ownedBoot: nil, battery: Self.reading(false, 80))
        saveSession(rig, duration: 8 * 3600, paused: .lowBattery)
        let outcome = rig.service.run()
        XCTAssertEqual(outcome.exitCode, .ok)
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertNil(rig.sessionStore.load())
        let lines = rig.auditLog.load()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.step, "sessionReconcile")
    }

    // MARK: — Battery step

    /// Critical battery with an indefinite session: still protected. The
    /// backstop releases, sleeps, and the session is PAUSED (not ended), so the
    /// operator's switch survives the episode.
    func testCriticalBatteryReleasesAndSleepsWithAnIndefiniteSession() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        saveSession(rig, duration: nil)
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.batteryMutation, "released")
        XCTAssertEqual(report.batteryReason, .criticalOwned)
        XCTAssertTrue(report.sleepAttempted)
        XCTAssertEqual(rig.flag.value, false)
        XCTAssertEqual(rig.sleeper.count, 1, "release is followed by pmset sleepnow")
        XCTAssertEqual(rig.lid.calls, [false])
        XCTAssertEqual(rig.sessionStore.load()?.pausedReason, .lowBattery)
        XCTAssertTrue(rig.latchStore.load().latch.releasedByGuard, "the re-arm debt is recorded")
        let lines = rig.auditLog.load()
        XCTAssertEqual(lines.first?.step, "batteryRelease")
        XCTAssertEqual(lines.first?.outcome, "released")
    }

    /// Critical battery, the plain switch, no session at all: the battery rule
    /// still protects it once the app is gone.
    func testCriticalBatteryProtectsThePlainSwitchWithoutASession() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 5))
        let outcome = rig.service.run()
        XCTAssertEqual(outcome.exitCode, .ok)
        XCTAssertEqual(rig.flag.value, false)
        XCTAssertEqual(rig.sleeper.count, 1)
        XCTAssertFalse(rig.sessionStore.exists, "no session file is invented")
    }

    /// A flag set by another tool (no record): never mutated (B2). The fast
    /// path does not even enter the lock, so there is no release attempt.
    func testForeignFlagIsNeverReleased() {
        var rig = makeRig(flag: true, ownedBoot: nil, battery: Self.reading(true, 4))
        let outcome = rig.service.run()
        XCTAssertEqual(outcome, .nothingToDo, "no record claims the flag → nothing to protect")
        XCTAssertEqual(rig.flag.value, true)
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertEqual(rig.sleeper.count, 0)
    }

    /// A claim from a previous boot + critical battery is the ADR 022 emergency
    /// path: released as `.lowBatteryEmergency`.
    func testCriticalBatteryWithAPreviousBootRecordReleasesAsAnEmergency() {
        var rig = makeRig(flag: true, ownedBoot: "OLD", battery: Self.reading(true, 6))
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.batteryReason, .emergencyStaleOwnership)
        XCTAssertEqual(report.batteryMutation, "released")
        XCTAssertEqual(rig.flag.value, false)
        XCTAssertEqual(rig.sleeper.count, 1)
    }

    /// Good battery with a flag we own: nothing to do beyond a live evaluation.
    func testGoodBatteryDoesNotAct() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 55))
        let outcome = rig.service.run()
        XCTAssertEqual(outcome.exitCode, .ok)
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertEqual(rig.sleeper.count, 0)
        XCTAssertTrue(rig.auditLog.load().isEmpty)
    }

    // MARK: — Never an ON action

    /// THE invariant: a pending re-arm debt with a good battery and AC power is
    /// WITHHELD, not performed. The flag stays OFF and the debt stays on disk
    /// for the app.
    func testPendingRearmDebtIsNotPerformedAndTheFlagStaysOff() {
        var rig = makeRig(flag: false, ownedBoot: "OLD", battery: Self.reading(false, 40))
        rig.latchStore.save(.init(latch: LowBatteryPolicy.Latch(releasedByGuard: true),
                                  releasedBootID: "OLD"))
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.batteryMutation, "rearmWithheld")
        XCTAssertEqual(rig.lid.calls, [], "no enable call, ever")
        XCTAssertEqual(rig.flag.value, false, "the flag stays OFF")
        let latch = rig.latchStore.load().latch
        XCTAssertTrue(latch.releasedByGuard, "the debt is left for the app")
        let lines = rig.auditLog.load()
        XCTAssertEqual(lines.first?.step, "batteryRearm")
        XCTAssertEqual(lines.first?.outcome, "withheld")
    }

    /// Exhaustive-ish: over a grid of power states, the backstop never issues an
    /// enable. `FakeLid.calls` would contain `true` if it ever did.
    func testTheBackstopNeverEnablesTheFlag() {
        let batteryStates: [BatteryState] = [
            Self.reading(true, 3), Self.reading(true, 9, 4), Self.reading(true, 19),
            Self.reading(true, 60), Self.reading(false, 5), Self.reading(false, 40),
            Self.reading(false, 80), Self.reading(nil, nil),
        ]
        for state in batteryStates {
            for ownedBoot in ["A", "OLD"] {
                for flag in [true, false] {
                    var rig = makeRig(flag: flag, ownedBoot: ownedBoot, battery: state)
                    rig.latchStore.save(.init(latch: LowBatteryPolicy.Latch(releasedByGuard: true)))
                    _ = rig.service.run()
                    XCTAssertFalse(rig.lid.calls.contains(true),
                                   "an enable was issued for \(state) ownedBoot=\(ownedBoot) flag=\(flag)")
                }
            }
        }
    }

    /// The two steps are independent protections: a failed session release must
    /// not stop the battery rule from running, and the run reports the failure.
    func testBatteryStepStillRunsWhenTheSessionStepFailed() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)
        rig.lid.failWrites = true
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.session?.expiry, .retained("sudo: a password is required"))
        XCTAssertEqual(report.batteryMutation, "releaseFailed", "the battery step ran anyway")
        XCTAssertEqual(outcome.exitCode, .backendFailure)
        XCTAssertNotNil(rig.sessionStore.load(), "the session record is kept for a retry")
    }

    // MARK: — Lock discipline

    /// The regression ADR 023 established for the tick, extended to the
    /// backstop: it takes `LidWriteLock` ONCE for the whole protective section.
    /// A nested `withLock` would open a second fd on the same file and block
    /// forever — so this test FAILS BY NAME after 10 s instead of hanging.
    func testTheBackstopDoesNotNestTheWriteLock() {
        let rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)

        final class Run: @unchecked Sendable {
            var service: RecoveryBackstopService
            var outcome: RecoveryBackstopService.Outcome?
            let done: XCTestExpectation
            init(_ s: RecoveryBackstopService, _ e: XCTestExpectation) { service = s; done = e }
        }
        let run = Run(rig.service, expectation(description: "backstop returns"))
        Thread { run.outcome = run.service.run(); run.done.fulfill() }.start()
        let waited = XCTWaiter().wait(for: [run.done], timeout: 10)
        guard waited == .completed else {
            return XCTFail("the backstop did not return: LidWriteLock is nested (deadlock)")
        }
        XCTAssertEqual(run.outcome?.exitCode, .ok)
        // And the section is released afterwards.
        XCTAssertEqual(LidWriteLock(url: rig.lockURL).tryWithLock { 1 }, 1)
    }

    /// The whole protective section is exclusive: a second non-blocking
    /// acquisition from another fd fails while the steps run. Proven by the
    /// lock file being held for the entire run — the service takes it once, and
    /// the session step and the battery step both run inside it.
    func testTheLockIsHeldForTheWholeSection() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)
        let other = LidWriteLock(url: rig.lockURL)
        final class Seen: @unchecked Sendable { var outside: [Bool] = [] }
        let seen = Seen()
        let current = rig.battery
        // The battery readback runs INSIDE the section (the guard evaluates
        // there), which is our probe point.
        rig.service.guardService = LowBatteryGuardService(
            lidService: rig.service.guardService.lidService,
            latchStore: rig.latchStore,
            batteryProvider: {
                seen.outside.append(other.tryWithLock { 1 } == nil)
                return current.state
            },
            sleeper: rig.sleeper,
            lock: LidWriteLock(url: rig.lockURL),
            auditLog: LowBatteryAuditLog(url: rig.lockURL.deletingLastPathComponent()
                .appendingPathComponent("low_battery_audit.jsonl")),
            sessionService: nil)
        _ = rig.service.run()
        XCTAssertFalse(seen.outside.isEmpty, "the battery step ran")
        XCTAssertTrue(seen.outside.allSatisfy { $0 }, "the section is exclusive")
        XCTAssertEqual(other.tryWithLock { 2 }, 2, "and released afterwards")
    }

    // MARK: — Exit codes

    func testExitCodeValues() {
        XCTAssertEqual(RecoveryBackstopService.ExitCode.ok.rawValue, 0)
        XCTAssertEqual(RecoveryBackstopService.ExitCode.refused.rawValue, 3)
        XCTAssertEqual(RecoveryBackstopService.ExitCode.backendFailure.rawValue, 5)
        XCTAssertEqual(RecoveryBackstopService.ExitCode.usage.rawValue, 64)
        XCTAssertEqual(RecoveryBackstopService.ExitCode.busy.rawValue, 75)
    }
}
