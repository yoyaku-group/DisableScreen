import XCTest
@testable import RunClosedCore

/// Pure recovery-backstop policy tests (ADR 024). No I/O, no `pmset`, no lock:
/// every case is a fact about the rules.
final class RecoveryPolicyTests: XCTestCase {

    private enum Boot {
        static let now = "boot-now"
        static let old = "boot-old"
    }
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func now(continuousSeconds: Double = 1_000,
                     bootID: String = Boot.now,
                     wallOffset: TimeInterval = 0) -> SessionPolicy.Now {
        SessionPolicy.Now(
            wall: Self.epoch.addingTimeInterval(wallOffset),
            continuousNanoseconds: ContinuousClockTimebase.nanoseconds(fromSeconds: continuousSeconds),
            bootID: bootID)
    }

    private func session(
        duration: TimeInterval?,
        bootID: String = Boot.now,
        startedAt offset: TimeInterval = 0,
        continuousStart: Double = 1_000,
        paused: SessionPauseReason? = nil
    ) -> KeepAwakeSession {
        KeepAwakeSession(
            startedAt: Self.epoch.addingTimeInterval(offset),
            endsAtWall: duration.map { Self.epoch.addingTimeInterval(offset).addingTimeInterval($0) },
            endsAtContinuous: duration.map {
                ContinuousClockTimebase.nanoseconds(fromSeconds: continuousStart + $0)
            },
            bootID: bootID,
            pausedReason: paused)
    }

    private func facts(
        recordBootID: String = Boot.now,
        ownedEnabled: Bool = false,
        session: KeepAwakeSession? = nil,
        now: SessionPolicy.Now? = nil,
        battery: LowBatteryPolicy.Input? = nil,
        latch: LowBatteryPolicy.Latch = LowBatteryPolicy.Latch()
    ) -> RecoveryPolicy.Facts {
        RecoveryPolicy.Facts(
            recordBootID: recordBootID,
            recordOwnedEnabled: ownedEnabled,
            currentBootID: Boot.now,
            session: session,
            now: now ?? self.now(),
            battery: battery,
            latch: latch)
    }

    private func batteryInput(onBattery: Bool?, pct: Int?, lidFlag: Bool?,
                              ownership: LowBatteryPolicy.LidOwnership = .ownedThisBoot,
                              minutes: Int? = nil) -> LowBatteryPolicy.Input {
        LowBatteryPolicy.Input(onBattery: onBattery, chargePercent: pct, minutesRemaining: minutes,
                               lidFlag: lidFlag, ownership: ownership, acDraining: nil)
    }

    // MARK: — Fast exit

    /// The whole point of the fast path: nothing is ours and nothing is
    /// scheduled, so the minute costs no `pmset` and no lock.
    func testNothingToDoWithNoRecordAndNoSession() {
        let plan = RecoveryPolicy.plan(facts())
        XCTAssertFalse(plan.needsWork)
        XCTAssertFalse(plan.session)
        XCTAssertFalse(plan.battery)
        XCTAssertEqual(plan.batteryVerdict, .unread)
    }

    /// A record that has released the flag (`ownedEnabled == false`) is not a
    /// claim, whatever boot wrote it.
    func testAReleasedRecordDoesNotClaimTheFlag() {
        let plan = RecoveryPolicy.plan(facts(recordBootID: Boot.old, ownedEnabled: false))
        XCTAssertFalse(plan.needsWork)
    }

    /// `lid-stay-awake on`, the battery re-arm and old records all leave the
    /// flag ours with NO session on disk. The fast path must not depend on
    /// `session.json` alone.
    func testOurRecordWithoutASessionStillNeedsWork() {
        let plan = RecoveryPolicy.plan(facts(ownedEnabled: true))
        XCTAssertTrue(plan.needsWork)
        XCTAssertTrue(plan.battery)
        XCTAssertFalse(plan.session)
        XCTAssertEqual(plan.ownership, .ownedThisBoot)
    }

    /// A record from a previous boot still claims the flag: it is exactly the
    /// case ADR 022's emergency release exists for.
    func testOurRecordFromAPreviousBootStillNeedsWork() {
        let plan = RecoveryPolicy.plan(facts(recordBootID: Boot.old, ownedEnabled: true))
        XCTAssertTrue(plan.needsWork)
        XCTAssertEqual(plan.ownership, .staleRecord)
    }

    /// A session with no ownership record still needs the session step: the
    /// deadline is a promise even if the flag went off behind our back.
    func testASessionAloneNeedsWork() {
        let plan = RecoveryPolicy.plan(facts(session: session(duration: 3600)))
        XCTAssertTrue(plan.needsWork)
        XCTAssertTrue(plan.session)
        XCTAssertFalse(plan.battery)
    }

    // MARK: — Due session

    func testADueSessionIsReportedAsDue() {
        let s = session(duration: 60)
        let plan = RecoveryPolicy.plan(facts(session: s, now: now(continuousSeconds: 1_000 + 61)))
        XCTAssertTrue(plan.sessionDue)
    }

    func testARunningSessionIsNotDue() {
        let s = session(duration: 3600)
        let plan = RecoveryPolicy.plan(facts(session: s, now: now(continuousSeconds: 1_000 + 60)))
        XCTAssertFalse(plan.sessionDue)
    }

    /// An indefinite session is never due — it is the plain switch.
    func testAnIndefiniteSessionIsNeverDue() {
        let s = session(duration: nil)
        let plan = RecoveryPolicy.plan(facts(session: s, now: now(continuousSeconds: 10_000_000)))
        XCTAssertFalse(plan.sessionDue)
        XCTAssertTrue(plan.session)
    }

    // MARK: — Battery verdict

    func testCriticalBatteryWithOurFlagReleases() {
        let verdict = RecoveryPolicy.batteryVerdict(
            input: batteryInput(onBattery: true, pct: 8, lidFlag: true),
            latch: LowBatteryPolicy.Latch())
        XCTAssertTrue(verdict.releasesFlag)
        XCTAssertEqual(verdict.reason, .criticalOwned)
    }

    /// A flag set by another tool is never mutated (B2) — alert only.
    func testCriticalBatteryWithAForeignFlagDoesNotRelease() {
        let verdict = RecoveryPolicy.batteryVerdict(
            input: batteryInput(onBattery: true, pct: 8, lidFlag: true, ownership: .notOwned),
            latch: LowBatteryPolicy.Latch())
        XCTAssertFalse(verdict.releasesFlag)
        XCTAssertEqual(verdict.reason, .criticalNotOwned)
    }

    /// Our own record from a previous boot is the ADR 022 emergency case: the
    /// backstop releases it, because leaving it on is the 2026-10-14 incident.
    func testCriticalBatteryWithAStaleOwnRecordReleasesAsAnEmergency() {
        let verdict = RecoveryPolicy.batteryVerdict(
            input: batteryInput(onBattery: true, pct: 6, lidFlag: true, ownership: .staleRecord),
            latch: LowBatteryPolicy.Latch())
        XCTAssertTrue(verdict.releasesFlag)
        XCTAssertEqual(verdict.reason, .emergencyStaleOwnership)
    }

    func testGoodBatteryDoesNotRelease() {
        let verdict = RecoveryPolicy.batteryVerdict(
            input: batteryInput(onBattery: true, pct: 60, lidFlag: true),
            latch: LowBatteryPolicy.Latch())
        XCTAssertFalse(verdict.releasesFlag)
        XCTAssertEqual(verdict.reason, .chargeOK)
    }

    /// UNKNOWN is not OFF (ADR 009) and a critical battery with an unreadable
    /// flag cannot be released — the backstop has nothing safe to do.
    func testCriticalBatteryWithAnUnknownFlagDoesNotRelease() {
        let verdict = RecoveryPolicy.batteryVerdict(
            input: batteryInput(onBattery: true, pct: 5, lidFlag: nil),
            latch: LowBatteryPolicy.Latch(releasedByGuard: true))
        XCTAssertFalse(verdict.releasesFlag)
        XCTAssertEqual(verdict.reason, .lidFlagUnknown)
    }

    // MARK: — Never an ON action

    /// THE rule of this lot: the backstop never turns the flag on. A pending
    /// re-arm debt on AC is therefore WITHHELD, never performed — the debt is
    /// left for the app.
    func testPendingRearmDebtOnACIsWithheldNotPerformed() {
        let verdict = RecoveryPolicy.batteryVerdict(
            input: batteryInput(onBattery: false, pct: 40, lidFlag: false),
            latch: LowBatteryPolicy.Latch(releasedByGuard: true))
        XCTAssertFalse(verdict.releasesFlag)
        XCTAssertEqual(verdict.reason, .rearmAfterRecovery)
        guard case .rearmWithheld = verdict else {
            return XCTFail("the re-arm must be withheld, got \(verdict)")
        }
    }

    /// Exhaustive guard over the policy's whole output space: NO combination
    /// produces an enable. The verdict type has no "enable" case at all, which
    /// this test pins from the outside.
    func testNoInputEverAsksTheBackstopToTurnTheFlagOn() {
        let flags: [Bool?] = [true, false, nil]
        let pcts: [Int?] = [nil, 0, 5, 10, 20, 40, 100]
        let sources: [Bool?] = [true, false, nil]
        let ownerships: [LowBatteryPolicy.LidOwnership] = [.ownedThisBoot, .staleRecord, .notOwned]
        let latches = [LowBatteryPolicy.Latch(),
                       LowBatteryPolicy.Latch(releasedByGuard: true),
                       LowBatteryPolicy.Latch(warnedLow: true, warnedCritical: true)]
        for flag in flags {
            for pct in pcts {
                for source in sources {
                    for ownership in ownerships {
                        for latch in latches {
                            let input = batteryInput(onBattery: source, pct: pct,
                                                     lidFlag: flag, ownership: ownership)
                            let verdict = RecoveryPolicy.batteryVerdict(input: input, latch: latch)
                            // The type carries only three shapes; the assertion
                            // that matters is that a release is never asked for
                            // an ON flag and never on AC.
                            if verdict.releasesFlag, source == false {
                                XCTFail("a release on AC: \(input) → \(verdict)")
                            }
                            if verdict.releasesFlag, flag != true {
                                XCTFail("a release without an observed ON flag: \(input) → \(verdict)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// The plan's verdict follows the supplied reading, and stays `.unread` on
    /// the file-only fast path (no battery read).
    func testPlanCarriesTheBatteryVerdictWhenAReadingIsSupplied() {
        let plan = RecoveryPolicy.plan(facts(
            ownedEnabled: true,
            battery: batteryInput(onBattery: true, pct: 7, lidFlag: true)))
        XCTAssertTrue(plan.batteryVerdict.releasesFlag)
        let unread = RecoveryPolicy.plan(facts(ownedEnabled: true))
        XCTAssertEqual(unread.batteryVerdict, .unread)
    }
}
