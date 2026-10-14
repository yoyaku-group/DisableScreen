import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// Action-path tests for the low-battery guard (ADR 022): fake lid backend,
/// fake sleeper, injected battery readings, temp-file stores. Nothing here
/// touches `pmset` — the fakes record what WOULD have been executed.
final class LowBatteryGuardServiceTests: XCTestCase {

    /// Fake lid backend whose readback flips the shared observed flag.
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

    private final class BatteryBox: @unchecked Sendable {
        var state: BatteryState
        init(_ s: BatteryState) { state = s }
    }

    private struct Rig {
        var service: LowBatteryGuardService
        let lid: FakeLid
        let sleeper: FakeSleeper
        let flag: FlagBox
        let battery: BatteryBox
        let lidStore: OwnedLidAssertion
        let latchStore: LowBatteryLatchStore
    }

    private static func reading(_ onBattery: Bool?, _ pct: Int?, _ minutes: Int? = nil) -> BatteryState {
        BatteryState(onBattery: onBattery, chargePercent: pct, minutesRemaining: minutes,
                     isCharging: onBattery == false, batteryPresent: true)
    }

    /// - `owned`: nil = no record, "A" = owned on this boot, "OLD" = stale.
    private func makeRig(flag: Bool?, ownedBoot: String?, battery: BatteryState) -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-lowbat-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lidStore = OwnedLidAssertion(currentBootID: "A", url: dir.appendingPathComponent("owned_lid.json"))
        if let b = ownedBoot {
            lidStore.save(.init(bootID: b, ownedEnabled: true, referenceState: "on"))
        }
        let latchStore = LowBatteryLatchStore(url: dir.appendingPathComponent("low_battery_guard.json"))
        let flagBox = FlagBox(flag)
        let lid = FakeLid(flag: flagBox)
        let sleeper = FakeSleeper()
        let batteryBox = BatteryBox(battery)
        let lidService = LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                            priorProvider: { flagBox.value })
        let service = LowBatteryGuardService(lidService: lidService, latchStore: latchStore,
                                             batteryProvider: { batteryBox.state }, sleeper: sleeper)
        return Rig(service: service, lid: lid, sleeper: sleeper, flag: flagBox,
                   battery: batteryBox, lidStore: lidStore, latchStore: latchStore)
    }

    // MARK: — Release path (owned on this boot)

    func testCriticalOwnedReleasesThenSleeps() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 9, 8))
        let out = rig.service.tick()
        XCTAssertEqual(out.evaluation.decision.action, .releaseAndSleep)
        XCTAssertEqual(rig.lid.calls, [false], "disablesleep 0 through the gated path")
        XCTAssertEqual(out.mutation, .released)
        XCTAssertEqual(rig.sleeper.count, 1)
        XCTAssertTrue(out.sleepAttempted)
        XCTAssertTrue(rig.latchStore.load().latch.releasedByGuard)
        XCTAssertEqual(rig.latchStore.load().releasedBootID, "A")
        XCTAssertFalse(rig.lidStore.load().ownedEnabled, "ownership released from the verified outcome")
    }

    func testSecondTickAfterReleaseDoesNotSleepAgain() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 9))
        rig.service.tick()
        let out = rig.service.tick()   // flag now reads OFF
        XCTAssertEqual(out.evaluation.decision.reason, .lidFlagOff)
        XCTAssertEqual(rig.sleeper.count, 1)
        XCTAssertEqual(rig.lid.calls, [false])
    }

    func testBackendFailureStillAttemptsSleepButKeepsNoReleaseLatch() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 5))
        rig.lid.failWrites = true
        let out = rig.service.tick()
        XCTAssertEqual(out.mutation, .releaseFailed)
        XCTAssertEqual(out.mutationError, "sudo: a password is required")
        XCTAssertEqual(rig.sleeper.count, 1, "best-effort sleep while we own the flag")
        XCTAssertFalse(rig.latchStore.load().latch.releasedByGuard, "no verified release, no latch")
    }

    // MARK: — Not owned: warn, never mutate (B2)

    func testStaleRecordNeverMutatesNorSleeps() {
        // The 2026-10-15 machine state: flag ON, record from the previous boot.
        var rig = makeRig(flag: true, ownedBoot: "OLD", battery: Self.reading(true, 6))
        let out = rig.service.tick()
        XCTAssertEqual(out.evaluation.input.ownership, .staleRecord)
        XCTAssertEqual(out.evaluation.decision.action, .warn)
        XCTAssertEqual(out.evaluation.decision.reason, .criticalStaleOwnership)
        XCTAssertNil(out.mutation)
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertEqual(rig.sleeper.count, 0)
        XCTAssertTrue(rig.latchStore.load().latch.warnedCritical)
    }

    func testFlagSetByAnotherToolNeverMutated() {
        var rig = makeRig(flag: true, ownedBoot: nil, battery: Self.reading(true, 3))
        let out = rig.service.tick()
        XCTAssertEqual(out.evaluation.decision.reason, .criticalNotOwned)
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertEqual(rig.sleeper.count, 0)
    }

    // MARK: — AC never acts

    func testACNeverActsEvenWhenCriticalAndOwned() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(false, 2, 1))
        let out = rig.service.tick()
        XCTAssertEqual(out.evaluation.decision.action, .none)
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertEqual(rig.sleeper.count, 0)
    }

    func testUnknownBatteryNeverActs() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: .unknown)
        rig.service.tick()
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertEqual(rig.sleeper.count, 0)
    }

    // MARK: — Hysteresis / re-arm

    func testFullCycleReleaseHoldRearm() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 10))
        rig.service.tick()                                   // release + sleep
        XCTAssertEqual(rig.flag.value, false)

        rig.battery.state = Self.reading(false, 12)          // charger back, 12%
        let held = rig.service.tick()
        XCTAssertEqual(held.evaluation.decision.reason, .rearmHeldBelowThreshold)
        XCTAssertEqual(rig.lid.calls, [false])

        rig.battery.state = Self.reading(false, 15)          // exactly 15%: still held
        rig.service.tick()
        XCTAssertEqual(rig.lid.calls, [false])

        rig.battery.state = Self.reading(false, 16)          // > 15% on AC: re-arm
        let rearm = rig.service.tick()
        XCTAssertEqual(rearm.mutation, .rearmed)
        XCTAssertEqual(rig.lid.calls, [false, true])
        XCTAssertEqual(rig.flag.value, true)
        XCTAssertFalse(rig.latchStore.load().latch.releasedByGuard)
        XCTAssertTrue(rig.lidStore.load().ownedEnabled, "re-armed flag is owned on this boot again")
    }

    func testRearmFailureKeepsLatchForRetry() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        rig.service.tick()
        rig.battery.state = Self.reading(false, 40)
        rig.lid.failWrites = true
        let out = rig.service.tick()
        XCTAssertEqual(out.mutation, .rearmFailed)
        XCTAssertTrue(rig.latchStore.load().latch.releasedByGuard)
    }

    func testOperatorCommandClearsPendingRearm() {
        var rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 8))
        rig.service.tick()
        rig.latchStore.clearPendingRearm()      // what the popup switch / CLI does
        rig.battery.state = Self.reading(false, 60)
        let out = rig.service.tick()
        XCTAssertEqual(out.evaluation.decision.action, .none)
        XCTAssertEqual(rig.lid.calls, [false], "no re-arm after a human decision")
    }

    // MARK: — Read-only evaluation

    func testEvaluateNeverMutatesOrPersists() {
        let rig = makeRig(flag: true, ownedBoot: "A", battery: Self.reading(true, 5))
        let e = rig.service.evaluate()
        XCTAssertEqual(e.decision.action, .releaseAndSleep)
        XCTAssertTrue(rig.lid.calls.isEmpty)
        XCTAssertEqual(rig.sleeper.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.latchStore.url.path),
                       "status must not write the latch")
    }

    func testKillSwitchDefaultsToEnabled() {
        let suite = "runclosed-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        XCTAssertTrue(LowBatteryGuardSettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: LowBatteryGuardSettings.enabledKey)
        XCTAssertFalse(LowBatteryGuardSettings.isEnabled(defaults: defaults))
        defaults.removePersistentDomain(forName: suite)
    }
}
