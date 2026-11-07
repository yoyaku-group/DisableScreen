import XCTest
@testable import RunClosedCore

/// The grace period measures ten minutes of heat that COULD be released, not
/// ten minutes of heat somewhere in the machine's past (ADR 025).
///
/// Scenario the rule exists for: the Mac runs `serious` for five minutes with
/// the lid closed, the operator opens it for fifteen (the machine cools, the
/// workload settles), then closes it again while still `serious`. Without the
/// hold, the stale timestamp makes the next tick release immediately and the
/// session ends on a spike that had already been cooled.
final class ThermalGraceHoldTests: XCTestCase {

    private let t0: Double = 1_000

    private func input(_ lid: Bool?, _ external: Bool? = false,
                       ownership: LowBatteryPolicy.LidOwnership = .ownedThisBoot,
                       at time: Double) -> ThermalPolicy.Input {
        ThermalPolicy.Input(state: .serious, lidClosed: lid,
                            externalDisplayConnected: external, lidFlag: true,
                            ownership: ownership, monotonic: time, bootID: "A")
    }

    /// An interruption CLEARS the clock: reopening the lid for fifteen minutes
    /// must not count towards the ten.
    func testAnInterruptionClearsTheSustainedClock() {
        // Five minutes enclosed, still inside the grace period.
        let start = ThermalPolicy.step(input(true, at: t0), latch: ThermalPolicy.Latch())
        XCTAssertEqual(start.decision.action, .warn)
        XCTAssertEqual(start.latch.seriousSince, t0)

        let fiveEnclosed = ThermalPolicy.step(input(true, at: t0 + 5 * 60), latch: start.latch)
        XCTAssertEqual(fiveEnclosed.decision.action, .none)

        // The lid opens: the release is no longer possible, so the clock stops.
        let opened = ThermalPolicy.step(input(false, at: t0 + 6 * 60), latch: fiveEnclosed.latch)
        XCTAssertNil(opened.latch.seriousSince, "an interruption ends the clock")
        XCTAssertNil(opened.latch.seriousSinceBootID)

        // Fifteen minutes pass with the lid open.
        var latch = opened.latch
        for minute in 7...21 {
            let tick = ThermalPolicy.step(input(false, at: t0 + Double(minute) * 60), latch: latch)
            latch = tick.latch
            XCTAssertNil(latch.seriousSince)
        }

        // The lid closes again. The clock restarts HERE, so nothing releases.
        let closedAgain = ThermalPolicy.step(input(true, at: t0 + 22 * 60), latch: latch)
        XCTAssertEqual(closedAgain.decision.action, .none,
                       "the stale five minutes must not make this tick release")
        XCTAssertEqual(closedAgain.latch.seriousSince, t0 + 22 * 60)

        // Ten minutes of the NEW enclosure is what releases.
        let nineMore = ThermalPolicy.step(input(true, at: t0 + 31 * 60), latch: closedAgain.latch)
        XCTAssertEqual(nineMore.decision.action, .none)
        let tenMore = ThermalPolicy.step(input(true, at: t0 + 32 * 60), latch: nineMore.latch)
        XCTAssertEqual(tenMore.decision.action, .releaseAndSleep)
        XCTAssertEqual(tenMore.decision.reason, .seriousSustained)
    }

    /// A display appearing is an interruption of the same kind: the machine is
    /// in use, so the heat is not the situation the rule covers.
    func testAnAttachedDisplayClearsTheSustainedClock() {
        let start = ThermalPolicy.step(input(true, at: t0), latch: ThermalPolicy.Latch())
        let withDisplay = ThermalPolicy.step(input(true, true, at: t0 + 60), latch: start.latch)
        XCTAssertNil(withDisplay.latch.seriousSince)
        XCTAssertEqual(withDisplay.decision.action, .none)

        // The display goes away: the clock restarts from here.
        let back = ThermalPolicy.step(input(true, false, at: t0 + 10 * 60),
                                      latch: withDisplay.latch)
        XCTAssertEqual(back.latch.seriousSince, t0 + 10 * 60)
        XCTAssertEqual(back.decision.action, .none)
    }

    /// Losing ownership is an interruption too: the guard can no longer act.
    func testLosingOwnershipClearsTheSustainedClock() {
        let start = ThermalPolicy.step(input(true, at: t0), latch: ThermalPolicy.Latch())
        let foreign = ThermalPolicy.step(input(true, false, ownership: .notOwned,
                                               at: t0 + 60), latch: start.latch)
        XCTAssertNil(foreign.latch.seriousSince, "the clock stops: no release is possible")
        // Still silent: the operator was already told about this episode, and
        // re-alerting every tick is the flood the latch exists to prevent. What
        // matters here is the clock, not a second notification.
        XCTAssertEqual(foreign.decision.action, .none)
    }

    /// The warning latch is NOT cleared by an interruption: the operator has
    /// already been told about this episode, and re-alerting on every lid
    /// flutter would be the flood the latch exists to prevent.
    func testAnInterruptionKeepsTheWarningLatch() {
        let start = ThermalPolicy.step(input(true, at: t0), latch: ThermalPolicy.Latch())
        XCTAssertTrue(start.latch.warnedSerious)
        let opened = ThermalPolicy.step(input(false, at: t0 + 60), latch: start.latch)
        XCTAssertTrue(opened.latch.warnedSerious, "no second heads-up for the same episode")

        // And closing again does NOT re-warn either.
        let closedAgain = ThermalPolicy.step(input(true, at: t0 + 120), latch: opened.latch)
        XCTAssertEqual(closedAgain.decision.action, .none)
    }

    /// Cooling completely still resets everything, warning latch included.
    func testCoolingStillResetsTheWholeLatch() {
        let start = ThermalPolicy.step(input(true, at: t0), latch: ThermalPolicy.Latch())
        let cooled = ThermalPolicy.step(
            ThermalPolicy.Input(state: .fair, lidClosed: true, externalDisplayConnected: false,
                                lidFlag: true, ownership: .ownedThisBoot,
                                monotonic: t0 + 60, bootID: "A"),
            latch: start.latch)
        XCTAssertEqual(cooled.latch, ThermalPolicy.Latch())
    }

    /// The behaviour the ADR table names, unchanged: a first observation of
    /// `serious` in an enclosed machine warns and starts the clock; nine
    /// minutes later it still does not release; ten it does.
    func testThePlainGracePeriodStillHolds() {
        let start = ThermalPolicy.step(input(true, at: t0), latch: ThermalPolicy.Latch())
        XCTAssertEqual(start.decision.action, .warn)
        let nine = ThermalPolicy.step(input(true, at: t0 + 9 * 60), latch: start.latch)
        XCTAssertEqual(nine.decision.action, .none)
        let ten = ThermalPolicy.step(input(true, at: t0 + 10 * 60), latch: nine.latch)
        XCTAssertEqual(ten.decision.action, .releaseAndSleep)
    }
}
