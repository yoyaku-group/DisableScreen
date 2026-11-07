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
        let heartbeat: BackstopHeartbeatStore
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
                         bootID: String = "A",
                         batteryGuardEnabled: Bool = true) -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-backstop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The grid test alone builds dozens of rigs; without this every run
        // leaves lock, audit and heartbeat files behind.
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
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
        let heartbeatStore = BackstopHeartbeatStore(
            url: dir.appendingPathComponent("backstop_heartbeat.json"))
        let service = RecoveryBackstopService(
            sessionService: sessionService,
            guardService: guardService,
            lock: LidWriteLock(url: lockURL),
            auditLog: auditLog,
            heartbeatStore: heartbeatStore,
            appIsAlive: { aliveBox.alive },
            batteryGuardEnabled: { batteryGuardEnabled },
            wallClock: { clock.wall })

        return Rig(service: service, lid: lid, sleeper: sleeper, flag: flagBox, clock: clock,
                   sessionStore: sessionStore, latchStore: latchStore, lidStore: lidStore,
                   battery: batteryBox, alive: aliveBox, lockURL: lockURL, auditLog: auditLog,
                   heartbeat: heartbeatStore)
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

    // MARK: — The operator's battery kill switch (round 2 addendum)

    /// The app skips the battery step when the guard is switched off and still
    /// runs the session step. The backstop is the same guard, so it must obey
    /// the same switch — otherwise an operator who turned it off would still
    /// get a `disablesleep 0` plus `pmset sleepnow` from launchd a minute later.
    func testTheBatteryKillSwitchStopsTheReleaseAndTheSleep() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6),
                          batteryGuardEnabled: false)
        let outcome = rig.service.run()
        XCTAssertEqual(outcome.exitCode, .ok)
        XCTAssertEqual(rig.flag.value, true, "the flag must stay ON when the guard is off")
        XCTAssertTrue(rig.lid.calls.isEmpty, "no release may be attempted")
        XCTAssertEqual(rig.sleeper.count, 0, "and no pmset sleepnow")
        XCTAssertEqual(outcome.batteryMutation, nil, "the battery step did not run")
        XCTAssertTrue(rig.auditLog.load().filter { $0.step == "batteryRelease" }.isEmpty)
    }

    /// …but the kill switch must NOT switch deadlines off with it: a due
    /// session still ends, the same split the app makes.
    func testTheBatteryKillSwitchDoesNotStopTheSessionStep() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6),
                          batteryGuardEnabled: false)
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.session?.expiry, .ended(.released),
                       "the deadline is not the battery guard's to switch off")
        XCTAssertEqual(rig.flag.value, false, "released by the session step")
        XCTAssertNil(rig.sessionStore.load())
        XCTAssertEqual(rig.sleeper.count, 0, "the session step never sleeps the Mac")
        XCTAssertEqual(report.batteryMutation, nil, "…and the battery step still did not run")
    }

    /// With the guard off and nothing scheduled, the minute stays free: no
    /// lock, no `pmset`.
    func testTheKillSwitchKeepsALoneClaimOnTheFastPath() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6),
                          batteryGuardEnabled: false)
        XCTAssertEqual(rig.service.run(), .nothingToDo)
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertEqual(rig.sleeper.count, 0)
    }

    /// The switch defaults to ON, so the production wiring is unchanged for
    /// everyone who never touched it.
    func testTheGuardDefaultsToEnabled() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        _ = rig.service.run()
        XCTAssertEqual(rig.flag.value, false, "a critical battery still releases by default")
        XCTAssertEqual(rig.sleeper.count, 1)
    }

    // MARK: — The backstop never consumes the app's warnings

    /// The backstop shows NO notification, so it must not persist the
    /// warn-once latch bits on the app's behalf. If it did, the app's next tick
    /// would answer `.alreadyWarned` after the operator reopens it, and the
    /// low-battery warning would never be shown — in the one situation where
    /// they most need it.
    func testABackstopWarningMinuteDoesNotConsumeTheAppsLatch() {
        // 15 % on battery, flag ours: `LowBatteryPolicy` warns (<= 20 %) and
        // would set `warnedLow`.
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 15))
        _ = rig.service.run()
        let latch = rig.latchStore.load().latch
        XCTAssertFalse(latch.warnedLow,
                       "the backstop delivers no warning, so it must leave the app's to deliver")
    }

    /// The re-arm debt IS this caller's to write: it is the app's signal to
    /// re-enable the flag, not a claim that anyone was informed.
    func testABackstopReleaseStillRecordsTheRearmDebt() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        _ = rig.service.run()
        XCTAssertTrue(rig.latchStore.load().latch.releasedByGuard)
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

    // MARK: — Heartbeat: proof the agent RUNS (ADR 024 §5)

    /// Written on the fast path too — a minute that legitimately did nothing
    /// still proves the agent fires.
    func testHeartbeatIsWrittenOnAFastPathRun() {
        var rig = makeRig(flag: nil, ownedBoot: nil, battery: Self.reading(false, 60))
        XCTAssertNil(rig.heartbeat.load())
        _ = rig.service.run()
        let hb = rig.heartbeat.load()
        XCTAssertNotNil(hb)
        XCTAssertEqual(hb?.exitCode, 0)
        XCTAssertEqual(hb?.bootID, "A")
    }

    /// …and when the app is alive, and when the lock is busy.
    func testHeartbeatIsWrittenWhenTheAppIsAliveAndWhenTheLockIsBusy() {
        var alive = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60),
                            appAlive: true)
        _ = alive.service.run()
        XCTAssertEqual(alive.heartbeat.load()?.bootID, "A")

        var busy = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        let other = LidWriteLock(url: busy.lockURL)
        _ = other.tryWithLock { busy.service.run() }
        XCTAssertEqual(busy.heartbeat.load()?.bootID, "A",
                       "a busy minute still proves the agent itself runs")
    }

    /// A failing run records exit 5, which is what makes the CLI refuse to
    /// trust it (a backstop that cannot act is not an enforcer).
    func testAFailingRunRecordsExit5InTheHeartbeat() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60))
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)
        rig.lid.failWrites = true
        let outcome = rig.service.run()
        XCTAssertEqual(outcome.exitCode, .backendFailure)
        XCTAssertEqual(rig.heartbeat.load()?.exitCode, 5)
    }

    /// A `nothingToDo`/`appAlive` minute proves the agent STARTS, not that it
    /// can ACT: it exits before the lock and before `pmset`. Until a locked run
    /// has completed on this boot, the CLI must not treat it as an enforcer.
    func testARunThatNeverTookTheLockIsNotProofItCanAct() {
        var rig = makeRig(flag: nil, ownedBoot: nil, battery: Self.reading(false, 60))
        _ = rig.service.run()   // nothingToDo: no lock
        XCTAssertEqual(rig.heartbeat.load()?.completedLockedRun, false,
                       "a fast-path minute ran no section")
        let freshness = RecoveryPolicy.runFreshnessFull(
            heartbeat: rig.heartbeat.freshnessInput(),
            currentBootID: "A", now: rig.clock.wall)
        XCTAssertEqual(freshness, .noLockedRunYet)
        XCTAssertFalse(freshness.isEnforcing)
    }

    /// …and once a locked run has completed, the proof survives later
    /// fast-path minutes on the SAME boot.
    func testACompletedLockedRunMakesLaterFastPathMinutesEnforcing() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        _ = rig.service.run()   // completed: took the lock
        XCTAssertEqual(rig.heartbeat.load()?.completedLockedRun, true)

        // The next minute finds nothing to do, but the proof is sticky.
        rig.lidStore.purge()
        rig.flag.value = false
        rig.clock.advance(60)
        _ = rig.service.run()
        XCTAssertEqual(rig.heartbeat.load()?.completedLockedRun, true)
        let freshness = RecoveryPolicy.runFreshnessFull(
            heartbeat: rig.heartbeat.freshnessInput(),
            currentBootID: "A", now: rig.clock.wall)
        XCTAssertTrue(freshness.isEnforcing, "got \(freshness)")
    }

    /// The whole point of the heartbeat: a run of the real service, on this
    /// boot, produces exactly the tuple the CLI's freshness rule grades as
    /// enforcing. This ties the writer and the reader together — a heartbeat
    /// the CLI would reject makes the agent unable to lift the ADR 023
    /// refusal, which is the failure this record exists to prevent.
    ///
    /// It uses `runFreshnessFull` on `freshnessInput()`, the SAME pair every
    /// production caller uses. An earlier version graded the run with the
    /// short wrapper, which hard-coded the locked-run proof — so it passed on a
    /// rule production never applies.
    func testARealRunProducesAHeartbeatTheCLIAcceptsAsEnforcing() {
        // A run that takes the lock: a critical battery with our flag gives it
        // something to do.
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        _ = rig.service.run()
        let freshness = RecoveryPolicy.runFreshnessFull(
            heartbeat: rig.heartbeat.freshnessInput(),
            currentBootID: "A",
            now: rig.clock.wall)
        XCTAssertTrue(freshness.isEnforcing, "got \(freshness)")

        // A heartbeat from another boot is NOT enforcing, even if identical.
        let otherBoot = RecoveryPolicy.runFreshnessFull(
            heartbeat: rig.heartbeat.freshnessInput(),
            currentBootID: "B",
            now: rig.clock.wall)
        XCTAssertFalse(otherBoot.isEnforcing)
    }

    // MARK: — Exit-code mapping of the battery step (round 2 review)

    /// A critical-battery release that FAILED must report a backend failure,
    /// not success. It previously exited 0 — a protective action that did not
    /// happen, announced as fine.
    func testFailedBatteryReleaseExits5() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        rig.lid.failWrites = true
        let outcome = rig.service.run()
        guard case .completed(let report) = outcome else {
            return XCTFail("expected a completed run, got \(outcome)")
        }
        XCTAssertEqual(report.batteryMutation, "releaseFailed")
        XCTAssertEqual(outcome.exitCode, .backendFailure)
        XCTAssertEqual(outcome.exitCode.rawValue, 5)
        XCTAssertEqual(rig.heartbeat.load()?.exitCode, 5)
    }

    /// A refusal (B1/B2) is exit 3: policy said no, nothing was attempted.
    ///
    /// The mapping is asserted on a constructed `Report` because the refusal is
    /// a genuine race that cannot be staged through the public surface: the
    /// ownership record must disappear AFTER the policy decided
    /// `releaseAndSleep` and BEFORE `LidMutationService`'s B2 gate reads it.
    /// Removing it earlier (in the battery readback) makes `evaluate()` see
    /// `notOwned` and downgrade the decision to a warning, so no release is
    /// ever attempted — which is exactly how the first version of this test
    /// silently checked nothing.
    func testRefusedBatteryReleaseExits3() {
        var report = RecoveryBackstopService.Report(
            plan: RecoveryPolicy.plan(RecoveryPolicy.Facts(
                recordBootID: "A", recordOwnedEnabled: true, currentBootID: "A",
                session: nil,
                now: SessionPolicy.Now(wall: epoch, continuousNanoseconds: 0, bootID: "A"))))
        report.batteryMutation = "releaseRefused"
        report.batteryReason = .criticalOwned
        report.batteryError = "notOwned"

        XCTAssertEqual(report.exitCode, .refused)
        XCTAssertEqual(report.exitCode.rawValue, 3)

        // And the other battery outcomes, side by side, so a change to any of
        // them fails here rather than in production.
        var released = report
        released.batteryMutation = "released"
        XCTAssertEqual(released.exitCode, .ok)

        var withheld = report
        withheld.batteryMutation = "rearmWithheld"
        withheld.batteryError = "a re-arm is the app's"
        XCTAssertEqual(withheld.exitCode, .ok)
    }

    /// `released`, `rearmWithheld` and "battery step did not run" keep exit 0.
    func testSuccessfulOrInertBatteryStepsKeepExit0() {
        var released = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 6))
        XCTAssertEqual(released.service.run().exitCode, .ok)

        var withheld = makeRig(flag: false, ownedBoot: "OLD", battery: Self.reading(false, 40))
        withheld.latchStore.save(.init(latch: LowBatteryPolicy.Latch(releasedByGuard: true),
                                       releasedBootID: "OLD"))
        XCTAssertEqual(withheld.service.run().exitCode, .ok)

        var inert = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 55))
        XCTAssertEqual(inert.service.run().exitCode, .ok)
    }

    /// A failed session release still wins over an inert battery step.
    func testSessionFailureWinsOverTheBatteryMapping() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60))
        saveSession(rig, duration: 60)
        rig.clock.advance(3_600)
        rig.lid.failWrites = true
        let outcome = rig.service.run()
        XCTAssertEqual(outcome.exitCode, .backendFailure)
    }

    // MARK: — rearmWithheld is audited once per episode (round 2 review)

    /// The condition holds for every minute it lasts. Two consecutive runs
    /// must produce exactly ONE audit line, not one per minute.
    func testRearmWithheldIsAuditedOncePerEpisode() {
        var rig = makeRig(flag: false, ownedBoot: "OLD", battery: Self.reading(false, 40))
        rig.latchStore.save(.init(latch: LowBatteryPolicy.Latch(releasedByGuard: true),
                                  releasedBootID: "OLD"))
        _ = rig.service.run()
        XCTAssertEqual(rig.auditLog.load().filter { $0.step == "batteryRearm" }.count, 1)

        rig.clock.advance(60)
        _ = rig.service.run()
        XCTAssertEqual(rig.auditLog.load().filter { $0.step == "batteryRearm" }.count, 1,
                       "a second minute in the same episode must not audit again")

        rig.clock.advance(60)
        _ = rig.service.run()
        XCTAssertEqual(rig.auditLog.load().filter { $0.step == "batteryRearm" }.count, 1)
    }

    /// Leaving the episode and coming back starts a NEW episode, which is
    /// audited again.
    func testLeavingTheEpisodeThenReturningAuditsAgain() {
        var rig = makeRig(flag: false, ownedBoot: "OLD", battery: Self.reading(false, 40))
        rig.latchStore.save(.init(latch: LowBatteryPolicy.Latch(releasedByGuard: true),
                                  releasedBootID: "OLD"))
        _ = rig.service.run()
        XCTAssertEqual(rig.auditLog.load().filter { $0.step == "batteryRearm" }.count, 1)

        // Out of the condition: on AC but still below the re-arm threshold, so
        // the policy asks for nothing at all and the episode closes.
        rig.battery.state = Self.reading(false, 12)
        rig.clock.advance(60)
        _ = rig.service.run()
        XCTAssertEqual(rig.auditLog.load().filter { $0.step == "batteryRearm" }.count, 1)

        // Back into it: a new episode, reported again.
        rig.battery.state = Self.reading(false, 40)
        rig.clock.advance(60)
        _ = rig.service.run()
        XCTAssertEqual(rig.auditLog.load().filter { $0.step == "batteryRearm" }.count, 2)
    }

    /// The episode flag survives a busy minute in the middle: a minute that
    /// never evaluated the battery must not open a new episode.
    func testABusyMinuteDoesNotResetTheEpisode() {
        var rig = makeRig(flag: false, ownedBoot: "OLD", battery: Self.reading(false, 40))
        rig.latchStore.save(.init(latch: LowBatteryPolicy.Latch(releasedByGuard: true),
                                  releasedBootID: "OLD"))
        _ = rig.service.run()
        XCTAssertEqual(rig.auditLog.load().filter { $0.step == "batteryRearm" }.count, 1)

        let other = LidWriteLock(url: rig.lockURL)
        _ = other.tryWithLock { rig.service.run() }   // busy: no battery step
        rig.clock.advance(60)
        _ = rig.service.run()
        XCTAssertEqual(rig.auditLog.load().filter { $0.step == "batteryRearm" }.count, 1,
                       "the episode stays open across a busy minute")
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
