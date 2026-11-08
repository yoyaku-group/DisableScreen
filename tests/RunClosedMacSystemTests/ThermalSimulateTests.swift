import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// `runclosed thermal simulate` is a PURE decision: it constructs the input,
/// prints the decision and touches nothing (ADR 025, same family as
/// `low-battery simulate`).
///
/// A CLI subprocess test would prove the printing but not the "no mutation"
/// claim — the binary would talk to the real `pmset`. So the pure path the CLI
/// runs is exercised here against a fake backend, and the assertion is on the
/// fake's own call log.
final class ThermalSimulateTests: XCTestCase {

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
        var count = 0
        func sleepNow() -> (rc: Int32, output: String?) {
            count += 1
            return (0, nil)
        }
    }

    /// The pure function the CLI's `simulate` runs — the same call, on a fake,
    /// so "it mutated nothing" is observable.
    private func simulate(state: ThermalState,
                          lidClosed: Bool? = true,
                          externalDisplay: Bool? = false,
                          lidFlag: Bool? = true,
                          ownership: LowBatteryPolicy.LidOwnership = .ownedThisBoot,
                          latch: ThermalPolicy.Latch = ThermalPolicy.Latch(),
                          monotonic: Double = 1_000)
        -> (decision: ThermalPolicy.Decision, latch: ThermalPolicy.Latch,
            lid: FakeLid, sleeper: FakeSleeper, latchURL: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-simulate-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let flagBox = FlagBox(lidFlag)
        let lid = FakeLid(flag: flagBox)
        let sleeper = FakeSleeper()
        let latchURL = dir.appendingPathComponent("thermal_guard.json")
        let service = ThermalGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid,
                                           store: OwnedLidAssertion(
                                               currentBootID: "A",
                                               url: dir.appendingPathComponent("owned_lid.json")),
                                           priorProvider: { flagBox.value }),
            latchStore: ThermalLatchStore(url: latchURL),
            thermalProvider: { state },
            lidClosedProvider: { lidClosed },
            externalDisplayProvider: { externalDisplay },
            monotonic: { monotonic },
            sleeper: sleeper,
            auditLog: ThermalAuditLog(url: dir.appendingPathComponent("thermal_audit.jsonl")))

        // What `cmdThermal` does for `simulate`: the PURE policy call, never
        // `service.step()`.
        let input = ThermalPolicy.Input(
            state: state, lidClosed: lidClosed, externalDisplayConnected: externalDisplay,
            lidFlag: lidFlag, ownership: ownership, monotonic: monotonic, bootID: "A")
        let (decision, next) = ThermalPolicy.step(input, latch: latch)
        return (decision, next, lid, sleeper, latchURL)
    }

    /// The headline contract: `simulate` never mutates — no `pmset` write, no
    /// sleep, no latch file, no audit line.
    func testSimulateNeverMutatesAnything() {
        for state in ThermalState.allCases {
            let r = simulate(state: state)
            XCTAssertEqual(r.lid.calls, [], "simulate must not write the flag (\(state))")
            XCTAssertEqual(r.sleeper.count, 0, "simulate must not sleep the Mac (\(state))")
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.latchURL.path),
                           "simulate must not write the latch (\(state))")
        }
    }

    /// The decisions `simulate` prints for the grid, so a script reading the
    /// JSON sees exactly what the guard would decide.
    func testSimulateReportsTheSameDecisionAsThePolicy() {
        XCTAssertEqual(simulate(state: .nominal).decision.action, .none)
        XCTAssertEqual(simulate(state: .fair).decision.action, .none)
        XCTAssertEqual(simulate(state: .serious).decision.action, .warn)
        XCTAssertEqual(simulate(state: .serious).decision.reason, .seriousWarn)
        XCTAssertEqual(simulate(state: .critical).decision.action, .releaseAndSleep)
        XCTAssertEqual(simulate(state: .critical).decision.reason, .criticalOwned)
        // The refusals, exactly as the ADR table spells them.
        XCTAssertEqual(simulate(state: .critical, lidClosed: false).decision.reason, .lidOpen)
        XCTAssertEqual(simulate(state: .critical, externalDisplay: true).decision.reason,
                       .externalDisplay)
        XCTAssertEqual(simulate(state: .critical, lidFlag: false).decision.reason, .lidFlagOff)
        XCTAssertEqual(simulate(state: .critical, lidFlag: nil).decision.reason, .lidFlagUnknown)
        XCTAssertEqual(simulate(state: .critical, ownership: .notOwned).decision.reason,
                       .notOwned)
    }

    /// The grace period is reproducible from the CLI: `--since 600` on a
    /// `serious` state prints `.releaseAndSleep`.
    func testSimulateCanPaintAnOpenSeriousEpisode() {
        // A heads-up already given (the normal shape nine minutes in), so the
        // tick is silent rather than re-warning.
        let open = ThermalPolicy.Latch(warnedSerious: true, seriousSince: 1_000,
                                       seriousSinceBootID: "A")
        let nine = simulate(state: .serious, latch: open, monotonic: 1_000 + 9 * 60)
        XCTAssertEqual(nine.decision.action, .none)
        XCTAssertEqual(nine.decision.reason, .seriousWarn)

        let ten = simulate(state: .serious, latch: open, monotonic: 1_000 + 10 * 60)
        XCTAssertEqual(ten.decision.action, .releaseAndSleep)
        XCTAssertEqual(ten.decision.reason, .seriousSustained)

        // With the heads-up NOT yet given, the same nine-minute tick still
        // speaks once (that is the CLI's `--since` default latch).
        let notYetWarned = simulate(state: .serious, monotonic: 1_000 + 9 * 60)
        XCTAssertEqual(notYetWarned.decision.action, .warn)
    }

    /// `simulate` echoes the latch it WOULD produce, which is what the `--json`
    /// output exposes as `latchAfter` — without persisting it.
    func testSimulateEchoesTheResultingLatchWithoutPersistingIt() {
        let fresh = simulate(state: .serious)
        XCTAssertTrue(fresh.latch.warnedSerious)
        XCTAssertEqual(fresh.latch.seriousSince, 1_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.latchURL.path))

        let critical = simulate(state: .critical)
        XCTAssertFalse(critical.latch.releasedForHeat,
                       "the policy never claims a release it did not perform")
    }

    /// No combination of the simulate grid can ask for an enable — the same
    /// sweep, run through the path the CLI actually calls.
    func testSimulateNeverProducesAnEnable() {
        for state in ThermalState.allCases {
            for lid in [true, false, nil] as [Bool?] {
                for external in [true, false, nil] as [Bool?] {
                    for flag in [true, false, nil] as [Bool?] {
                        for ownership in [LowBatteryPolicy.LidOwnership.ownedThisBoot,
                                          .staleRecord, .notOwned] {
                            let r = simulate(state: state, lidClosed: lid,
                                             externalDisplay: external, lidFlag: flag,
                                             ownership: ownership)
                            XCTAssertFalse(r.lid.calls.contains(true))
                            XCTAssertTrue([ThermalPolicy.Action.none, .warn, .releaseAndSleep]
                                .contains(r.decision.action))
                        }
                    }
                }
            }
        }
    }
}
