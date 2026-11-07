import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// The single shared tick (ADR 023 §5): session expiry runs INSIDE the same
/// `LidWriteLock` section as the low-battery step, and that section never
/// nests the lock. Both facts are asserted here rather than described.
final class SessionGuardTickTests: XCTestCase {

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

    /// Hooks called from INSIDE the tick: `session` from the session step
    /// (its wall clock), `battery` from the battery step (its readback).
    private final class Probe: @unchecked Sendable {
        var session: (() -> Void)?
        var battery: (() -> Void)?
    }

    private struct Rig {
        var guardService: LowBatteryGuardService
        var session: SessionService
        let lid: FakeLid
        let sleeper: FakeSleeper
        let flag: FlagBox
        let clock: ClockBox
        let sessionStore: SessionStore
        let latchStore: LowBatteryLatchStore
        let battery: BatteryBox
        let lockURL: URL
        let probe: Probe
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private static func reading(_ onBattery: Bool?, _ pct: Int?, _ minutes: Int? = nil) -> BatteryState {
        BatteryState(onBattery: onBattery, chargePercent: pct, minutesRemaining: minutes,
                     isCharging: onBattery == false, batteryPresent: true)
    }

    private func makeRig(flag: Bool?, ownedBoot: String?, battery: BatteryState) -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-tick-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lidStore = OwnedLidAssertion(currentBootID: "A",
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
        let clock = ClockBox(wall: epoch, continuous: 1_000)
        let lockURL = dir.appendingPathComponent("lid.lock")
        let probe = Probe()

        // The production wiring, on the same fake backend and stores as the
        // guard's own real LidMutationService below.
        let apply = SessionService.gatedLid(
            bootID: "A", makeMutator: { lid }, store: lidStore,
            priorProvider: { flagBox.value })

        let sessionService = SessionService(
            store: sessionStore, latchStore: latchStore, continuous: clock,
            wallClock: { probe.session?(); return clock.wall }, observedFlag: { flagBox.value },
            ownershipRecord: {
                let rec = lidStore.load()
                return (rec.bootID, rec.ownedEnabled)
            },
            applyLid: apply)

        let guardService = LowBatteryGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: latchStore,
            batteryProvider: { probe.battery?(); return batteryBox.state },
            sleeper: sleeper,
            lock: LidWriteLock(url: lockURL),
            auditLog: LowBatteryAuditLog(url: dir.appendingPathComponent("audit.jsonl")),
            sessionService: sessionService)

        return Rig(guardService: guardService, session: sessionService, lid: lid,
                   sleeper: sleeper, flag: flagBox, clock: clock,
                   sessionStore: sessionStore, latchStore: latchStore,
                   battery: batteryBox, lockURL: lockURL, probe: probe)
    }

    /// A live 2 h session starting from the rig's clock.
    private func saveSession(_ rig: Rig, duration: TimeInterval = 2 * 3600) {
        rig.sessionStore.save(KeepAwakeSession(
            startedAt: epoch,
            endsAtWall: epoch.addingTimeInterval(duration),
            endsAtContinuous: ContinuousClockTimebase.nanoseconds(fromSeconds: 1_000 + duration),
            bootID: "A"))
    }

    // MARK: — One tick, one lock section

    /// THE regression: the tick holds `LidWriteLock` for its whole body. If the
    /// session step took the lock again, `withLock` would open a second fd on
    /// the same file and block forever. A second non-blocking acquisition from
    /// another fd must also fail while the tick runs.
    func testTickDoesNotNestTheWriteLock() {
        let rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60))
        saveSession(rig, duration: 60)
        rig.clock.advance(111)

        // If the tick nests, it never returns — exactly the app-freezing
        // deadlock the rule prevents. Run it on its own thread so the test
        // FAILS by name after a timeout instead of hanging the whole job.
        final class Run: @unchecked Sendable {
            var guardService: LowBatteryGuardService
            var outcome: LowBatteryGuardService.TickOutcome?
            let done: XCTestExpectation
            init(_ g: LowBatteryGuardService, _ e: XCTestExpectation) { guardService = g; done = e }
        }
        let run = Run(rig.guardService, expectation(description: "tick returns"))
        Thread { run.outcome = run.guardService.tick(); run.done.fulfill() }.start()
        let waited = XCTWaiter().wait(for: [run.done], timeout: 10)
        guard waited == .completed else {
            // The thread is still blocked inside `withLock`: reading
            // `run.outcome` now would race it.
            return XCTFail("the tick did not return: LidWriteLock is nested (deadlock)")
        }
        XCTAssertEqual(run.outcome?.session, .ended(.released))

        // Nothing is still holding the lock afterwards.
        let other = LidWriteLock(url: rig.lockURL)
        var ran = false
        let acquired: Int? = other.tryWithLock { () -> Int in ran = true; return 1 }
        XCTAssertEqual(acquired, 1)
        XCTAssertTrue(ran)
    }

    /// The session expiry and the battery step share ONE section: probed from
    /// inside each step while `tick()` runs, no other writer can get in. A
    /// refactor that dropped the lock between the two steps fails here.
    func testTheLockIsExclusiveForTheWholeTick() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60))
        saveSession(rig)
        let other = LidWriteLock(url: rig.lockURL)
        final class Seen: @unchecked Sendable { var session: [Bool] = []; var battery: [Bool] = [] }
        let seen = Seen()
        rig.probe.session = { seen.session.append(other.tryWithLock { 1 } == nil) }
        rig.probe.battery = { seen.battery.append(other.tryWithLock { 1 } == nil) }
        _ = rig.guardService.tick()
        rig.probe.session = nil
        rig.probe.battery = nil
        XCTAssertFalse(seen.session.isEmpty, "the session step ran inside the tick")
        XCTAssertFalse(seen.battery.isEmpty, "the battery step ran inside the tick")
        XCTAssertTrue(seen.session.allSatisfy { $0 }, "locked during the session step")
        XCTAssertTrue(seen.battery.allSatisfy { $0 }, "locked during the battery step")
        XCTAssertEqual(other.tryWithLock { 2 }, 2, "and released afterwards")
    }

    // MARK: — Expiry end order

    func testTickExpiryReleasesAutomaticAndClears() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60))
        saveSession(rig, duration: 60)
        rig.clock.advance(111)
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.session, .ended(.released))
        XCTAssertTrue(outcome.sessionEndedNaturally)
        XCTAssertEqual(rig.lid.calls, [false], "the session release is the only write")
        XCTAssertNil(rig.sessionStore.load())
    }

    func testTickExpiryOfAFlagAlreadyOffClearsWithoutMutation() {
        var rig = makeRig(flag: false, ownedBoot: nil, battery: Self.reading(false, 60))
        saveSession(rig, duration: 60)
        rig.clock.advance(111)
        // No ownership, flag observed OFF: the session has nothing to protect.
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.session, .ended(.flagAlreadyOff))
        XCTAssertTrue(outcome.sessionEndedNaturally)
        XCTAssertTrue(rig.lid.calls.isEmpty, "no release write on an already-off flag")
        XCTAssertNil(rig.sessionStore.load())
    }

    /// Review round 7: the flag is ON with no RunClosed owner at the
    /// deadline. The tick must not tell the operator the session simply
    /// ended — the Mac is still awake.
    func testTickExpiryWithTheFlagLeftOnIsNotANaturalEnd() {
        var rig = makeRig(flag: true, ownedBoot: nil, battery: Self.reading(false, 60))
        saveSession(rig, duration: 60)
        rig.clock.advance(111)
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.session, .ended(.flagLeftOn))
        XCTAssertFalse(outcome.sessionEndedNaturally)
        XCTAssertEqual(rig.flag.value, true)
        XCTAssertTrue(rig.lid.calls.isEmpty, "B2: no release write on a flag we do not own")
        XCTAssertNil(rig.sessionStore.load())
    }

    /// Review round 7: the rig runs the real gate, which maps a `.failed`
    /// write to `backendFailed`. The record stays for the next tick.
    func testTickExpiryRetainsTheRecordWhenTheWriteFails() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 60))
        saveSession(rig, duration: 60)
        rig.clock.advance(111)
        rig.lid.failWrites = true
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.session, .retained("sudo: a password is required"))
        XCTAssertFalse(outcome.sessionEndedNaturally)
        XCTAssertNotNil(rig.sessionStore.load())
        XCTAssertEqual(rig.flag.value, true)
    }

    func testTickIsSilentWithNoSession() {
        var rig = makeRig(flag: false, ownedBoot: nil, battery: Self.reading(false, 60))
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.session, .noSession)
        XCTAssertFalse(outcome.sessionEndedNaturally)
    }

    // MARK: — Battery release pauses, re-arm resumes

    func testBatteryReleasePausesTheSessionRatherThanEndingIt() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        saveSession(rig)
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.mutation, .released)
        XCTAssertEqual(rig.sleeper.count, 1)
        let paused = rig.sessionStore.load()
        XCTAssertEqual(paused?.pausedReason, .lowBattery, "the session is paused, not ended")
        XCTAssertNotNil(paused?.endsAtWall, "the deadline survives a battery episode")
        XCTAssertTrue(rig.latchStore.load().latch.releasedByGuard)
    }

    func testRearmResumesAStillValidSession() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        saveSession(rig)
        _ = rig.guardService.tick()                       // release + pause
        XCTAssertEqual(rig.sessionStore.load()?.pausedReason, .lowBattery)

        rig.battery.state = Self.reading(false, 40)       // back on AC above 15%
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.mutation, .rearmed)
        XCTAssertTrue(outcome.sessionResumed)
        XCTAssertNil(rig.sessionStore.load()?.pausedReason, "the countdown resumes")
        XCTAssertEqual(rig.lid.calls, [false, true])
    }

    /// The re-arm happens only while the session is still valid: once the
    /// deadline passed, the guard must not bring the flag back on.
    func testRearmIsWithheldWhenTheSessionIsDue() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        saveSession(rig, duration: 600)
        _ = rig.guardService.tick()                       // release + sleep
        // The Mac stayed asleep past the deadline, then came back on AC.
        rig.clock.advance(3 * 3600)
        rig.battery.state = Self.reading(false, 40)
        let outcome = rig.guardService.tick()
        XCTAssertNil(outcome.mutation, "no re-arm for a session that is over")
        XCTAssertEqual(rig.lid.calls, [false], "the flag stays off")
        XCTAssertNil(rig.sessionStore.load(), "the due session ended on this tick")
    }

    func testSessionEndCancelsAPendingRearmAcrossTheTick() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        saveSession(rig)
        _ = rig.guardService.tick()                       // release, latch armed
        XCTAssertTrue(rig.latchStore.load().latch.releasedByGuard)
        _ = rig.session.end()                             // the operator presses End
        XCTAssertFalse(rig.latchStore.load().latch.releasedByGuard)
        rig.battery.state = Self.reading(false, 60)
        let outcome = rig.guardService.tick()
        XCTAssertNil(outcome.mutation)
        XCTAssertEqual(rig.lid.calls, [false], "no re-arm after End")
    }

    // MARK: — ADR 022 unchanged without a session

    func testTickWithoutASessionKeepsADR022Behaviour() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 9, 8))
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.mutation, .released)
        XCTAssertEqual(outcome.session, .noSession)
        XCTAssertEqual(rig.sleeper.count, 1)
        XCTAssertTrue(rig.latchStore.load().latch.releasedByGuard)
        XCTAssertFalse(rig.sessionStore.exists, "no session file is invented")
    }

    func testTickWithoutASessionStillRearms() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        _ = rig.guardService.tick()
        rig.battery.state = Self.reading(false, 40)
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.mutation, .rearmed)
        XCTAssertFalse(outcome.sessionResumed, "nothing to resume without a session")
        XCTAssertEqual(rig.lid.calls, [false, true])
    }

    // MARK: — Review round 2: re-arm across a reboot

    /// The plain switch after a reboot: ADR 022 still re-arms it.
    func testPlainSwitchIsRearmedAfterAReboot() {
        var rig = makeRig(flag: false, ownedBoot: "OLD", battery: Self.reading(false, 40))
        rig.sessionStore.save(KeepAwakeSession(startedAt: epoch, bootID: "OLD"))
        rig.latchStore.save(.init(latch: .init(releasedByGuard: true)))
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.mutation, .rearmed)
        XCTAssertEqual(rig.lid.calls, [true])
    }

    /// A timed session from another boot never gets the flag back, and the
    /// debt is voided once rather than refused on every tick.
    func testTimedSessionFromAnotherBootVoidsTheRearmOnce() {
        var rig = makeRig(flag: false, ownedBoot: "OLD", battery: Self.reading(false, 40))
        rig.sessionStore.save(KeepAwakeSession(
            startedAt: epoch,
            endsAtWall: epoch.addingTimeInterval(4 * 3600),
            endsAtContinuous: ContinuousClockTimebase.nanoseconds(fromSeconds: 1_000 + 4 * 3600),
            bootID: "OLD"))
        rig.latchStore.save(.init(latch: .init(releasedByGuard: true)))
        let first = rig.guardService.tick()
        XCTAssertNil(first.mutation)
        XCTAssertNotNil(first.mutationError)
        XCTAssertFalse(rig.latchStore.load().latch.releasedByGuard, "debt voided")
        let second = rig.guardService.tick()
        XCTAssertNil(second.mutation)
        XCTAssertNil(second.mutationError, "no refusal repeated every tick")
        XCTAssertEqual(rig.lid.calls, [], "the flag stays off")
    }

    // MARK: — Review round 4: a pause ends when the flag is back

    /// The operator turned the flag back on themselves (switch or CLI) while
    /// the session was paused: the next tick resumes the countdown, so the
    /// menu bar no longer says "Paused" while the Mac is awake.
    func testPauseEndsWhenTheOperatorTurnsTheFlagBackOn() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        saveSession(rig)
        _ = rig.guardService.tick()                       // release + pause
        XCTAssertEqual(rig.sessionStore.load()?.pausedReason, .lowBattery)
        _ = rig.guardService.lidService.setEnabled(true, initiator: .operatorCommand)
        rig.latchStore.clearPendingRearm()                // the operator command supersedes it
        rig.battery.state = Self.reading(false, 40)
        let outcome = rig.guardService.tick()
        XCTAssertNil(outcome.mutation)
        XCTAssertTrue(outcome.sessionResumed)
        XCTAssertNil(rig.sessionStore.load()?.pausedReason)
    }

    /// Same, with the re-arm debt still pending: the guard finds the flag
    /// already ON and the session resumes too.
    func testPauseEndsWhenTheRearmFindsTheFlagAlreadyOn() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        saveSession(rig)
        _ = rig.guardService.tick()
        _ = rig.guardService.lidService.setEnabled(true, initiator: .operatorCommand)
        rig.battery.state = Self.reading(false, 40)
        let outcome = rig.guardService.tick()
        XCTAssertTrue(outcome.sessionResumed)
        XCTAssertNil(rig.sessionStore.load()?.pausedReason)
    }

    /// While the flag stays OFF and the re-arm is still owed, the pause
    /// stays: nothing is keeping the Mac awake, and saying so is the point of
    /// the pause.
    func testPauseStaysWhileTheFlagIsOffAndTheRearmIsOwed() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        saveSession(rig)
        _ = rig.guardService.tick()
        rig.battery.state = Self.reading(false, 12)       // charging, below the re-arm threshold
        let outcome = rig.guardService.tick()
        XCTAssertFalse(outcome.sessionResumed)
        XCTAssertNil(outcome.sessionReconciled)
        XCTAssertEqual(rig.sessionStore.load()?.pausedReason, .lowBattery)
        XCTAssertEqual(rig.flag.value, false)
    }

    /// Review round 6: the operator cancelled the re-arm with an OFF command.
    /// Nothing will resume the pause, so the next tick clears the session
    /// instead of leaving "Paused" on screen until the deadline.
    func testPauseWithACancelledRearmIsCleared() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        saveSession(rig)
        _ = rig.guardService.tick()
        rig.latchStore.clearPendingRearm()
        rig.battery.state = Self.reading(false, 40)
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.sessionReconciled, .cleared)
        XCTAssertNil(rig.sessionStore.load())
        XCTAssertEqual(rig.flag.value, false, "a cancelled re-arm stays cancelled")
    }

    // MARK: — Review round 5: orphan sessions

    /// The process died between writing the record and setting the flag
    /// (journal before change): a running session over a flag that reads
    /// OFF. The next tick clears it instead of counting down for nothing.
    func testTickClearsARunningSessionWhoseFlagReadsOff() {
        var rig = makeRig(flag: false, ownedBoot: nil, battery: Self.reading(false, 80))
        saveSession(rig)
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.session, .notDue)
        XCTAssertEqual(outcome.sessionReconciled, .cleared)
        XCTAssertNil(rig.sessionStore.load())
        XCTAssertEqual(rig.lid.calls, [], "nothing to write: the flag is already off")
    }

    /// UNKNOWN is not OFF (ADR 009): an unreadable flag leaves the session.
    func testTickLeavesTheSessionWhenTheFlagIsUnknown() {
        var rig = makeRig(flag: nil, ownedBoot: "A", battery: Self.reading(false, 80))
        saveSession(rig)
        let outcome = rig.guardService.tick()
        XCTAssertNil(outcome.sessionReconciled)
        XCTAssertNotNil(rig.sessionStore.load())
    }

    func testTickLeavesARunningSessionWhoseFlagIsOn() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 80))
        saveSession(rig)
        let outcome = rig.guardService.tick()
        XCTAssertNil(outcome.sessionReconciled)
        XCTAssertNotNil(rig.sessionStore.load())
    }

    /// The guard released the flag but the pause was never written: flag OFF
    /// with the re-arm debt pending is a battery pause, restored — and the
    /// re-arm on AC then revives the session.
    func testTickRestoresALostBatteryPause() {
        var rig = makeRig(flag: false, ownedBoot: nil, battery: Self.reading(true, 8))
        saveSession(rig)
        rig.latchStore.save(.init(latch: LowBatteryPolicy.Latch().recordingRelease(), releasedBootID: "A"))
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.sessionReconciled, .repaused)
        XCTAssertEqual(rig.sessionStore.load()?.pausedReason, .lowBattery)
        XCTAssertTrue(rig.latchStore.load().latch.releasedByGuard, "the re-arm debt stays")
    }

    /// With the low-battery guard switched off the app runs the session step
    /// alone: a deadline still ends the session.
    func testSessionStepAloneEndsADueSession() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 80))
        saveSession(rig, duration: 60)
        rig.clock.advance(61)
        let step = LidWriteLock(url: rig.lockURL).withLock { rig.session.step() }
        XCTAssertEqual(step.expiry, .ended(.released))
        XCTAssertNil(step.reconciled)
        XCTAssertEqual(rig.flag.value, false)
        XCTAssertNil(rig.sessionStore.load())
    }

    // MARK: — A session that became due while the app was CLOSED (ADR 024 §4)

    /// The app's FIRST tick at launch must end a session whose deadline passed
    /// while it was not running — otherwise the session record (written by the
    /// previous run, kept because the quit could not read the flag off) would
    /// count down for a deadline nobody enforces.
    ///
    /// Modelled on the real case: the record is from a PREVIOUS boot, so the
    /// continuous deadline is meaningless and the wall clock decides; the
    /// ownership record is from that same previous boot, so the release runs
    /// `.sessionRecovery(bootID:)`.
    func testFirstLaunchTickEndsASessionThatBecameDueWhileTheAppWasClosed() {
        var rig = makeRig(flag: true, ownedBoot: "OLD",
                          battery: Self.reading(false, 80))
        rig.sessionStore.save(KeepAwakeSession(
            startedAt: epoch.addingTimeInterval(-8 * 3600),
            endsAtWall: epoch.addingTimeInterval(-3600),   // lapsed an hour ago
            endsAtContinuous: ContinuousClockTimebase.nanoseconds(fromSeconds: 1_000),
            bootID: "OLD"))
        // The app opens and its first guard tick runs.
        let outcome = rig.guardService.tick()
        XCTAssertEqual(outcome.session, .ended(.released))
        XCTAssertTrue(outcome.sessionEndedNaturally)
        XCTAssertEqual(rig.lid.calls, [false], "the release is the only write")
        XCTAssertEqual(rig.flag.value, false)
        XCTAssertNil(rig.sessionStore.load())
    }

    /// Same case with the low-battery guard switched off: the launch runs the
    /// session step alone, and the deadline still ends.
    func testFirstLaunchSessionOnlyTickEndsALapsedSession() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 80))
        rig.sessionStore.save(KeepAwakeSession(
            startedAt: epoch,
            endsAtWall: epoch.addingTimeInterval(60),
            endsAtContinuous: ContinuousClockTimebase.nanoseconds(fromSeconds: 1_060),
            bootID: "A"))
        // Closed for three hours: the deadline lapsed while the app was gone.
        rig.clock.advance(3 * 3600)
        let step = LidWriteLock(url: rig.lockURL).withLock { rig.session.step() }
        XCTAssertEqual(step.expiry, .ended(.released))
        XCTAssertEqual(rig.flag.value, false)
        XCTAssertNil(rig.sessionStore.load())
    }
}
