import XCTest
@testable import RunClosedCore

/// The pure thermal policy (ADR 025): the grid from the ADR, the grace period,
/// the episode reset, and the exhaustive sweep that proves no combination can
/// ever ask for an `enable`.
final class ThermalPolicyTests: XCTestCase {

    /// `seriousSustainedAt` — the monotonic reading that trips the 10 min grace.
    private let t0: Double = 1_000

    private func input(_ state: ThermalState,
                       lid: Bool? = true,
                       external: Bool? = false,
                       flag: Bool? = true,
                       ownership: LowBatteryPolicy.LidOwnership = .ownedThisBoot,
                       monotonic: Double? = nil,
                       bootID: String = "A") -> ThermalPolicy.Input {
        ThermalPolicy.Input(state: state, lidClosed: lid, externalDisplayConnected: external,
                            lidFlag: flag, ownership: ownership,
                            monotonic: monotonic ?? t0, bootID: bootID)
    }

    // MARK: — The table

    func testNominalAndFairNeverAct() {
        for state in [ThermalState.nominal, .fair] {
            let (d, latch) = ThermalPolicy.step(input(state), latch: ThermalPolicy.Latch())
            XCTAssertEqual(d.action, .none, "\(state) has nothing to protect")
            XCTAssertEqual(d.reason, state == .nominal ? .nominal : .fair)
            XCTAssertEqual(latch, ThermalPolicy.Latch(), "no latch is set by a cool machine")
        }
    }

    func testSeriousEnclosedOwnedWarnsOnce() {
        let first = ThermalPolicy.step(input(.serious), latch: ThermalPolicy.Latch())
        XCTAssertEqual(first.decision.action, .warn)
        XCTAssertEqual(first.decision.reason, .seriousWarn)
        XCTAssertTrue(first.latch.warnedSerious)
        XCTAssertEqual(first.latch.seriousSince, t0, "the grace period starts now")

        // Every later tick of the same episode is silent.
        let second = ThermalPolicy.step(input(.serious, monotonic: t0 + 60),
                                        latch: first.latch)
        XCTAssertEqual(second.decision.action, .none)
        XCTAssertEqual(second.decision.reason, .seriousWarn)
    }

    /// 9 minutes does not release, 10 does.
    func testSeriousNineMinutesDoesNotReleaseAndTenDoes() {
        let start = ThermalPolicy.step(input(.serious), latch: ThermalPolicy.Latch())
        let nine = ThermalPolicy.step(
            input(.serious, monotonic: t0 + 9 * 60), latch: start.latch)
        XCTAssertEqual(nine.decision.action, .none, "9 min is still a grace period")
        XCTAssertEqual(nine.decision.reason, .seriousWarn)

        let ten = ThermalPolicy.step(
            input(.serious, monotonic: t0 + 10 * 60), latch: nine.latch)
        XCTAssertEqual(ten.decision.action, .releaseAndSleep)
        XCTAssertEqual(ten.decision.reason, .seriousSustained)
    }

    /// The boundary is inclusive: exactly at the threshold the guard acts.
    func testTheSustainedThresholdIsInclusive() {
        var latch = ThermalPolicy.Latch(seriousSince: t0, seriousSinceBootID: "A")
        latch.warnedSerious = true
        let atThreshold = ThermalPolicy.step(
            input(.serious, monotonic: t0 + ThermalPolicy.sustainedReleaseSeconds),
            latch: latch)
        XCTAssertEqual(atThreshold.decision.action, .releaseAndSleep)

        let oneSecondEarly = ThermalPolicy.step(
            input(.serious, monotonic: t0 + ThermalPolicy.sustainedReleaseSeconds - 1),
            latch: latch)
        XCTAssertEqual(oneSecondEarly.decision.action, .none)
    }

    /// A return to `fair` resets the counter: a session must not end because a
    /// machine ran `serious` for four minutes, cooled, then went `serious`
    /// again for four minutes.
    func testCoolingResetsTheCounter() {
        let start = ThermalPolicy.step(input(.serious), latch: ThermalPolicy.Latch())
        let cooled = ThermalPolicy.step(input(.fair, monotonic: t0 + 5 * 60),
                                        latch: start.latch)
        XCTAssertEqual(cooled.latch, ThermalPolicy.Latch(), "the episode is over")
        XCTAssertNil(cooled.latch.seriousSince)

        // The second run restarts the clock from now, not from the first one.
        let again = ThermalPolicy.step(input(.serious, monotonic: t0 + 6 * 60),
                                       latch: cooled.latch)
        XCTAssertEqual(again.latch.seriousSince, t0 + 6 * 60)
        let eightMinutesAfterTheFirst = ThermalPolicy.step(
            input(.serious, monotonic: t0 + 8 * 60), latch: again.latch)
        XCTAssertEqual(eightMinutesAfterTheFirst.decision.action, .none,
                       "the counter restarted, so 8 min since the FIRST run is not enough")
    }

    func testNominalAlsoResetsTheCounter() {
        let start = ThermalPolicy.step(input(.serious), latch: ThermalPolicy.Latch())
        let cooled = ThermalPolicy.step(input(.nominal, monotonic: t0 + 60),
                                        latch: start.latch)
        XCTAssertEqual(cooled.latch, ThermalPolicy.Latch())
    }

    func testCriticalEnclosedOwnedReleasesImmediately() {
        let (d, _) = ThermalPolicy.step(input(.critical), latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .releaseAndSleep)
        XCTAssertEqual(d.reason, .criticalOwned)
        XCTAssertEqual(d.state, .critical)
    }

    /// `critical` does not need the grace period, but it does NOT need to have
    /// started one either: the very first tick releases.
    func testCriticalReleasesOnTheFirstTickWithNoPriorLatch() {
        let (d, latch) = ThermalPolicy.step(input(.critical, monotonic: t0),
                                            latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .releaseAndSleep)
        XCTAssertNil(latch.seriousSince)
    }

    // MARK: — The three refusals

    /// B2: a critical temperature on a flag that is not ours never writes.
    func testCriticalNotOwnedAlertsOnly() {
        let (d, latch) = ThermalPolicy.step(
            input(.critical, ownership: .notOwned), latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .notOwned)
        // The once-per-episode bit follows the SEVERITY: a critical episode
        // sets `warnedCritical`, so a later `serious` refusal in the same
        // episode still gets its own heads-up. `warnedSerious` stays clear
        // here for exactly that reason.
        XCTAssertTrue(latch.warnedCritical, "the critical bit gates the repeat")
        XCTAssertFalse(latch.warnedSerious)
        XCTAssertFalse(latch.releasedForHeat)
    }

    /// A stale record of ours is NOT active ownership: the heat rule has no
    /// emergency widening (unlike ADR 022's battery one).
    func testCriticalStaleRecordAlertsOnly() {
        let (d, _) = ThermalPolicy.step(
            input(.critical, ownership: .staleRecord), latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .notOwned)
    }

    func testCriticalLidOpenDoesNotWrite() {
        let (d, _) = ThermalPolicy.step(input(.critical, lid: false),
                                        latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .lidOpen)
    }

    func testCriticalWithAnExternalDisplayDoesNotWrite() {
        let (d, _) = ThermalPolicy.step(input(.critical, external: true),
                                        latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .externalDisplay)
    }

    /// UNKNOWN is not `false` (ADR 009): an unreadable lid or an unreadable
    /// display both refuse, so the doubt never releases.
    func testUnknownLidRefuses() {
        let (d, _) = ThermalPolicy.step(input(.critical, lid: nil),
                                        latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .lidUnknown)
    }

    func testUnknownDisplayRefuses() {
        let (d, _) = ThermalPolicy.step(input(.critical, external: nil),
                                        latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .externalDisplay)
    }

    /// B1: a flag we cannot read is a flag we cannot release.
    func testUnknownFlagRefuses() {
        let (d, _) = ThermalPolicy.step(input(.critical, flag: nil),
                                        latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .lidFlagUnknown)
    }

    /// A hot machine with the flag already OFF needs no action and no alert.
    func testFlagOffIsInert() {
        for state in [ThermalState.serious, .critical] {
            let (d, latch) = ThermalPolicy.step(input(state, flag: false),
                                                latch: ThermalPolicy.Latch())
            XCTAssertEqual(d.action, .none)
            XCTAssertEqual(d.reason, .lidFlagOff)
            XCTAssertEqual(latch, ThermalPolicy.Latch())
        }
    }

    /// The refusals are announced ONCE per episode for `critical`, then silent.
    func testCriticalRefusalWarnsOnce() {
        let first = ThermalPolicy.step(input(.critical, ownership: .notOwned),
                                       latch: ThermalPolicy.Latch())
        XCTAssertEqual(first.decision.action, .warn)
        let second = ThermalPolicy.step(input(.critical, ownership: .notOwned),
                                        latch: first.latch)
        XCTAssertEqual(second.decision.action, .none)
        XCTAssertEqual(second.decision.reason, .notOwned)
    }

    /// `serious` with the lid open or a display attached is the ordinary shape
    /// of heavy work: no alert at all.
    func testSeriousWithAirCirculatingIsSilent() {
        for (lid, external) in [(false, false), (true, true), (false, true)] as [(Bool, Bool)] {
            let (d, latch) = ThermalPolicy.step(
                input(.serious, lid: lid, external: external), latch: ThermalPolicy.Latch())
            XCTAssertEqual(d.action, .none)
            XCTAssertFalse(latch.warnedSerious)
        }
    }

    /// `serious` and not ours: worth one heads-up, because the operator has to
    /// turn the switch off and on to give the guard the flag.
    func testSeriousNotOwnedWarnsOnce() {
        let (d, _) = ThermalPolicy.step(input(.serious, ownership: .notOwned),
                                        latch: ThermalPolicy.Latch())
        XCTAssertEqual(d.action, .warn)
        XCTAssertEqual(d.reason, .notOwned)
    }

    // MARK: — Monotonic timestamp hygiene

    /// A `seriousSince` written on another boot means nothing: the counter
    /// restarts at boot, so it must be discarded rather than compared.
    func testASeriousSinceFromAnotherBootIsDiscarded() {
        let latch = ThermalPolicy.Latch(seriousSince: 5, seriousSinceBootID: "OLD")
        let first = ThermalPolicy.step(input(.serious, monotonic: 100, bootID: "A"),
                                       latch: latch)
        XCTAssertEqual(first.latch.seriousSince, 100, "restarted from this boot's clock")
        XCTAssertEqual(first.latch.seriousSinceBootID, "A")
        // The alert is NOT re-emitted from the discarded latch alone: this
        // latch never warned, so the new episode gets its one heads-up here.
        // (The re-alert proof lives in the persistence/service tests, where a
        // warned latch survives a restart.)
        XCTAssertEqual(first.decision.action, .warn)
        XCTAssertEqual(first.decision.reason, .seriousWarn)
    }

    /// The grace period only advances while the release is actually possible:
    /// a machine that becomes enclosed at minute 9 releases at minute 19, not
    /// immediately (otherwise opening and closing the lid would be an exploit).
    func testTheClockStartsWhenTheMachineBecomesEnclosed() {
        // 9 minutes of `serious` with the lid OPEN: no timer at all.
        var latch = ThermalPolicy.Latch()
        for minute in 0..<9 {
            let (d, next) = ThermalPolicy.step(
                input(.serious, lid: false, monotonic: t0 + Double(minute) * 60), latch: latch)
            latch = next
            XCTAssertEqual(d.action, .none)
        }
        XCTAssertNil(latch.seriousSince, "an open lid never starts the clock")

        // Now the lid closes: the clock starts HERE.
        let enclosed = ThermalPolicy.step(input(.serious, monotonic: t0 + 9 * 60), latch: latch)
        XCTAssertEqual(enclosed.latch.seriousSince, t0 + 9 * 60)
        XCTAssertEqual(enclosed.decision.action, .warn)

        // 9 minutes of enclosure is not enough...
        let notYet = ThermalPolicy.step(
            input(.serious, monotonic: t0 + 18 * 60), latch: enclosed.latch)
        XCTAssertEqual(notYet.decision.action, .none)
        // ...10 minutes is.
        let now = ThermalPolicy.step(
            input(.serious, monotonic: t0 + 19 * 60), latch: notYet.latch)
        XCTAssertEqual(now.decision.action, .releaseAndSleep)
    }

    // MARK: — The sweep: the policy can never turn the flag ON

    /// Exhaustive over the whole input grid the policy reads. Same shape as the
    /// ADR 024 sweep: `Action` has no `enable` case, and this proves no
    /// combination smuggles one in through a decision that would be executed.
    func testNoCombinationEverAsksToEnableTheFlag() {
        let states = ThermalState.allCases
        let lids: [Bool?] = [true, false, nil]
        let externals: [Bool?] = [true, false, nil]
        let flags: [Bool?] = [true, false, nil]
        let ownerships: [LowBatteryPolicy.LidOwnership] = [.ownedThisBoot, .staleRecord, .notOwned]
        let times: [Double] = [t0, t0 + ThermalPolicy.sustainedReleaseSeconds]

        var combinations = 0
        for state in states {
            for lid in lids {
                for external in externals {
                    for flag in flags {
                        for ownership in ownerships {
                            for time in times {
                                for boot in ["A", "OLD"] {
                                    combinations += 1
                                    let latch = ThermalPolicy.Latch(
                                        seriousSince: t0, seriousSinceBootID: "A")
                                    let (d, _) = ThermalPolicy.step(
                                        input(state, lid: lid, external: external, flag: flag,
                                              ownership: ownership, monotonic: time, bootID: boot),
                                        latch: latch)
                                    // The type has three cases; "never enable" is
                                    // therefore a statement about the ACTION SET,
                                    // which this assert pins so a future case
                                    // cannot be added silently.
                                    XCTAssertTrue(
                                        [ThermalPolicy.Action.none, .warn, .releaseAndSleep]
                                            .contains(d.action),
                                        "unexpected action \(d.action) for \(state) lid=\(String(describing: lid)) ext=\(String(describing: external)) flag=\(String(describing: flag)) own=\(ownership)")
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(combinations, 4 * 3 * 3 * 3 * 3 * 2 * 2,
                       "the sweep must cover the whole grid")
    }

    /// The sweep's stronger form, stated as a rule: a release is only ever
    /// asked for when the flag is ON, ours, the lid is CLOSED and no display is
    /// attached. That is the invariant the three refusals exist to guarantee.
    func testAReleaseOnlyEverHappensOnAnEnclosedOwnedOnFlag() {
        let states = ThermalState.allCases
        var releases = 0
        for state in states {
            for lid in [true, false, nil] as [Bool?] {
                for external in [true, false, nil] as [Bool?] {
                    for flag in [true, false, nil] as [Bool?] {
                        for ownership in [LowBatteryPolicy.LidOwnership.ownedThisBoot,
                                          .staleRecord, .notOwned] {
                            let (d, _) = ThermalPolicy.step(
                                input(state, lid: lid, external: external, flag: flag,
                                      ownership: ownership,
                                      monotonic: t0 + ThermalPolicy.sustainedReleaseSeconds),
                                latch: ThermalPolicy.Latch(seriousSince: t0,
                                                           seriousSinceBootID: "A"))
                            guard d.action == .releaseAndSleep else { continue }
                            releases += 1
                            XCTAssertTrue(state.isHot, "a cool machine never releases")
                            XCTAssertEqual(flag, true, "the flag must be observed ON")
                            XCTAssertEqual(lid, true, "the lid must be observed CLOSED")
                            XCTAssertEqual(external, false, "no display may be attached")
                            XCTAssertEqual(ownership, .ownedThisBoot, "the flag must be ours")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(releases, 0, "the sweep must actually exercise the release path")
    }

    // MARK: — Codable / tolerance

    /// Unknown keys must not make an existing latch file read as corrupt: a
    /// reset latch would re-alert on every tick and restart the grace period.
    func testLatchDecodingToleratesFutureKeys() throws {
        let json = """
        {"warnedSerious":true,"warnedCritical":false,"seriousSince":12.5,
         "seriousSinceBootID":"A","releasedForHeat":false,"aFutureKey":42}
        """
        let latch = try JSONDecoder().decode(ThermalPolicy.Latch.self, from: Data(json.utf8))
        XCTAssertTrue(latch.warnedSerious)
        XCTAssertEqual(latch.seriousSince, 12.5)
        XCTAssertEqual(latch.seriousSinceBootID, "A")
    }

    func testLatchDecodingDefaultsEveryMissingKey() throws {
        let latch = try JSONDecoder().decode(
            ThermalPolicy.Latch.self, from: Data("{}".utf8))
        XCTAssertEqual(latch, ThermalPolicy.Latch())
    }

    func testRecordingReleaseSetsTheFlagWithoutTouchingTheRest() {
        let latch = ThermalPolicy.Latch(warnedSerious: true, seriousSince: 3,
                                        seriousSinceBootID: "A")
        let next = latch.recordingRelease()
        XCTAssertTrue(next.releasedForHeat)
        XCTAssertTrue(next.warnedSerious)
        XCTAssertEqual(next.seriousSince, 3)
    }

    // MARK: — ThermalState helpers

    func testThermalStatePredicates() {
        XCTAssertFalse(ThermalState.nominal.isHot)
        XCTAssertFalse(ThermalState.fair.isHot)
        XCTAssertTrue(ThermalState.serious.isHot)
        XCTAssertTrue(ThermalState.serious.isSerious)
        XCTAssertFalse(ThermalState.serious.isCritical)
        XCTAssertTrue(ThermalState.critical.isHot)
        XCTAssertTrue(ThermalState.critical.isCritical)
        XCTAssertFalse(ThermalState.critical.isSerious)
    }

    func testIsEnclosedOnlyWhenClosedWithNoDisplay() {
        XCTAssertTrue(input(.serious).isEnclosed)
        XCTAssertFalse(input(.serious, lid: false).isEnclosed)
        XCTAssertFalse(input(.serious, external: true).isEnclosed)
        XCTAssertFalse(input(.serious, lid: nil).isEnclosed)
        XCTAssertFalse(input(.serious, external: nil).isEnclosed)
    }
}
