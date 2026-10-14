import XCTest
@testable import RunClosedCore

/// Pure policy tests (ADR 022) — injected readings only, no IOKit, no pmset.
final class LowBatteryPolicyTests: XCTestCase {

    private typealias P = LowBatteryPolicy

    private func input(
        battery: Bool? = true, pct: Int? = 50, minutes: Int? = nil,
        lid: Bool? = true, ownership: P.LidOwnership = .ownedThisBoot
    ) -> P.Input {
        P.Input(onBattery: battery, chargePercent: pct, minutesRemaining: minutes,
                lidFlag: lid, ownership: ownership)
    }

    private func step(_ i: P.Input, _ latch: P.Latch = P.Latch()) -> (P.Decision, P.Latch) {
        let r = P.step(i, latch: latch)
        return (r.decision, r.latch)
    }

    // MARK: — Thresholds

    func testWarnAtTwentyPercent() {
        let (d, l) = step(input(pct: 20))
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .lowBattery)
        XCTAssertEqual(d.level, .low)
        XCTAssertTrue(l.warnedLow)
    }

    func testLowWarningSaysUnprotectedWhenFlagIsNotOwned() {
        // Review finding: the 20% notice must not promise a sleep that the
        // guard will refuse at 10% (stale record / other tool / unreadable).
        XCTAssertEqual(step(input(pct: 19, ownership: .staleRecord)).0.reason, .lowBatteryUnprotected)
        XCTAssertEqual(step(input(pct: 19, ownership: .notOwned)).0.reason, .lowBatteryUnprotected)
        XCTAssertEqual(step(input(pct: 19, lid: nil)).0.reason, .lowBatteryUnprotected)
        XCTAssertEqual(step(input(pct: 19)).0.reason, .lowBattery)
    }

    func testNoActionAboveWarnThreshold() {
        let (d, _) = step(input(pct: 21))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .chargeOK)
    }

    func testReleaseAndSleepAtTenPercentWhenOwned() {
        let (d, _) = step(input(pct: 10))
        XCTAssertEqual(d.action, .releaseAndSleep)
        XCTAssertEqual(d.reason, .criticalOwned)
        XCTAssertEqual(d.level, .critical)
    }

    func testElevenPercentIsOnlyAWarning() {
        let (d, _) = step(input(pct: 11))
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.level, .low)
    }

    func testIncidentReplayReleasesAtNinePercentEightMinutes() {
        // `runclosed low-battery simulate true 9 8` — the 2026-10-14 shape.
        let (d, _) = step(input(pct: 9, minutes: 8))
        XCTAssertEqual(d.action, .releaseAndSleep)
    }

    // MARK: — Time-to-empty trigger

    func testTenMinutesLeftInsideWarnBandIsCritical() {
        let (d, _) = step(input(pct: 15, minutes: 10))
        XCTAssertEqual(d.action, .releaseAndSleep)
        XCTAssertEqual(d.level, .critical)
    }

    func testElevenMinutesLeftIsNotCritical() {
        let (d, _) = step(input(pct: 15, minutes: 11))
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.level, .low)
    }

    func testNoisyEstimateAtHighChargeNeverSleeps() {
        // Right after unplugging, macOS can briefly report a few minutes.
        let (d, _) = step(input(pct: 80, minutes: 3))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.level, .ok)
    }

    // MARK: — AC and unknown never act

    func testACNeverActsEvenAtOnePercent() {
        for (pct, minutes) in [(1, 1), (5, nil), (10, 2), (20, nil)] as [(Int, Int?)] {
            let (d, _) = step(input(battery: false, pct: pct, minutes: minutes))
            XCTAssertEqual(d.action, .none, "AC must never act (pct=\(pct))")
            XCTAssertEqual(d.level, .ac)
        }
    }

    func testUnknownPowerSourceNeverActs() {
        let (d, _) = step(input(battery: nil, pct: 3))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .powerSourceUnknown)
    }

    func testOnBatteryWithUnknownChargeNeverActs() {
        let (d, _) = step(input(pct: nil, minutes: 2))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.level, .unknown)
    }

    // MARK: — Ownership (B2) — never mutate what we do not own

    func testCriticalWithStaleRecordWarnsAndNeverReleases() {
        let (d, l) = step(input(pct: 5, ownership: .staleRecord))
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .criticalStaleOwnership)
        XCTAssertTrue(l.warnedCritical)
    }

    func testCriticalNotOwnedWarnsAndNeverReleases() {
        let (d, _) = step(input(pct: 5, ownership: .notOwned))
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .criticalNotOwned)
    }

    func testCriticalNotOwnedWarnsOnlyOnce() {
        let (_, l1) = step(input(pct: 9, ownership: .notOwned))
        let (d2, _) = step(input(pct: 8, ownership: .notOwned), l1)
        XCTAssertEqual(d2.action, .none)
        XCTAssertEqual(d2.reason, .alreadyWarned)
    }

    func testCriticalWithUnknownFlagWarnsInsteadOfMutating() {
        // B1: UNKNOWN ≠ OFF and UNKNOWN ≠ ON — never release blind.
        let (d, _) = step(input(pct: 5, lid: nil))
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .lidFlagUnknown)
    }

    func testCriticalWithFlagOffDoesNothing() {
        // macOS keeps its own emergency sleep when the flag is off.
        let (d, _) = step(input(pct: 4, lid: false))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .lidFlagOff)
    }

    func testLowWithFlagOffDoesNotWarn() {
        let (d, _) = step(input(pct: 18, lid: false))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .lidFlagOff)
    }

    func testOwnershipClassification() {
        XCTAssertEqual(P.LidOwnership.classify(recordBootID: "A", recordOwnedEnabled: true, currentBootID: "A"), .ownedThisBoot)
        XCTAssertEqual(P.LidOwnership.classify(recordBootID: "A", recordOwnedEnabled: true, currentBootID: "B"), .staleRecord)
        XCTAssertEqual(P.LidOwnership.classify(recordBootID: "A", recordOwnedEnabled: false, currentBootID: "A"), .notOwned)
        XCTAssertEqual(P.LidOwnership.classify(recordBootID: "A", recordOwnedEnabled: false, currentBootID: "B"), .notOwned)
    }

    // MARK: — Latch / anti-flap

    func testLowWarningIsNotRepeated() {
        let (_, l1) = step(input(pct: 20))
        let (d2, l2) = step(input(pct: 19), l1)
        XCTAssertEqual(d2.action, .none)
        XCTAssertEqual(d2.reason, .alreadyWarned)
        XCTAssertEqual(l2, l1)
    }

    func testNoRepeatedSleepOnceTheFlagIsReleased() {
        // After a verified release the flag reads OFF: a wake at 8% must not
        // put the Mac straight back to sleep every 30 s.
        let released = P.Latch(releasedByGuard: true)
        let (d, l) = step(input(pct: 8, lid: false), released)
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .lidFlagOff)
        XCTAssertTrue(l.releasedByGuard, "re-arm still owed")
    }

    func testWarningsResetOnlyOnACAboveWarnBand() {
        let warned = P.Latch(warnedLow: true, warnedCritical: true)
        // Weak charger at 18%: keep the latch (no re-notification flapping).
        let (_, kept) = step(input(battery: false, pct: 18), warned)
        XCTAssertTrue(kept.warnedLow)
        XCTAssertTrue(kept.warnedCritical)
        // Charged above 20% on AC: a new discharge episode may warn again.
        let (_, reset) = step(input(battery: false, pct: 21), warned)
        XCTAssertFalse(reset.warnedLow)
        XCTAssertFalse(reset.warnedCritical)
        let failed = P.Latch(failedReleaseSleepTried: true)
        XCTAssertTrue(step(input(battery: false, pct: 18), failed).1.failedReleaseSleepTried)
        XCTAssertFalse(step(input(battery: false, pct: 21), failed).1.failedReleaseSleepTried)
        // On battery the latch never resets.
        let (_, onBattery) = step(input(battery: true, pct: 60), warned)
        XCTAssertTrue(onBattery.warnedLow)
    }

    // MARK: — Hysteresis (re-arm only on AC AND > 15%)

    func testRearmHeldAtFifteenPercentOnAC() {
        let (d, l) = step(input(battery: false, pct: 15, lid: false), P.Latch(releasedByGuard: true))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .rearmHeldBelowThreshold)
        XCTAssertTrue(l.releasedByGuard)
    }

    func testRearmAtSixteenPercentOnAC() {
        let (d, l) = step(input(battery: false, pct: 16, lid: false), P.Latch(releasedByGuard: true))
        XCTAssertEqual(d.action, .rearm)
        XCTAssertEqual(d.reason, .rearmAfterRecovery)
        XCTAssertTrue(l.releasedByGuard, "cleared only from the verified outcome")
    }

    func testRearmHeldWhileACIsDraining() {
        // Review pass 4: a 100 W adapter too weak for the fleet (-194 mA on
        // AC, 2026-10-15) must not get disablesleep re-enabled.
        var i = input(battery: false, pct: 40, lid: false)
        i.acDraining = true
        let (d, l) = step(i, P.Latch(releasedByGuard: true))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .rearmHeldACDraining)
        XCTAssertTrue(l.releasedByGuard)
        i.acDraining = false
        XCTAssertEqual(step(i, P.Latch(releasedByGuard: true)).0.action, .rearm)
    }

    func testACDrainingHelper() {
        XCTAssertEqual(P.Input.acDraining(onBattery: false, currentMilliamps: -194), true)
        XCTAssertEqual(P.Input.acDraining(onBattery: false, currentMilliamps: -20), false, "noise margin")
        XCTAssertEqual(P.Input.acDraining(onBattery: false, currentMilliamps: 3000), false)
        XCTAssertNil(P.Input.acDraining(onBattery: true, currentMilliamps: -2000))
        XCTAssertNil(P.Input.acDraining(onBattery: false, currentMilliamps: nil))
    }

    func testNoRearmOnBatteryEvenWhenCharged() {
        let (d, _) = step(input(battery: true, pct: 90, lid: false), P.Latch(releasedByGuard: true))
        XCTAssertEqual(d.action, .none)
    }

    func testNoRearmWithUnknownChargeOnAC() {
        let (d, _) = step(input(battery: false, pct: nil, lid: false), P.Latch(releasedByGuard: true))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .rearmHeldBelowThreshold)
    }

    func testFlagObservedOnClearsPendingRearm() {
        // A human re-enabled the switch: observation clears the debt.
        let (d, l) = step(input(battery: false, pct: 40, lid: true), P.Latch(releasedByGuard: true))
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .rearmObservedOn)
        XCTAssertFalse(l.releasedByGuard)
    }

    func testLatchHelpersAreWriteFromOutcome() {
        let l = P.Latch()
        XCTAssertTrue(l.recordingRelease().releasedByGuard)
        XCTAssertFalse(l.recordingRelease().recordingRearm().releasedByGuard)
    }
}
