import XCTest
@testable import RunClosedCore

/// Pure policy tests — no backend, no persistence, no pmset. Mirrors the
/// DisplayMutationPolicyTests structure exactly so the G2c policy stays in
/// step with the G2b one.
final class LidMutationPolicyTests: XCTestCase {

    // MARK: — Setting ON

    func testSetOnAllowedWhenPriorIsOff() {
        XCTAssertTrue(LidMutationPolicy.canSet(enabled: true, observedPrior: false))
    }

    func testSetOnRefusedWhenPriorIsOn() {
        // No-op: writing `on` over an observed `on` is refused so the service
        // emits an explicit "already in that state" rather than silent success.
        XCTAssertFalse(LidMutationPolicy.canSet(enabled: true, observedPrior: true))
    }

    func testSetOnRefusedOnUnknownPrior() {
        // B1: unknown prior blocks every mutation (UNKNOWN ≠ OFF).
        XCTAssertFalse(LidMutationPolicy.canSet(enabled: true, observedPrior: nil))
    }

    // MARK: — Setting OFF

    func testSetOffAllowedWhenPriorIsOn() {
        XCTAssertTrue(LidMutationPolicy.canSet(enabled: false, observedPrior: true))
    }

    func testSetOffRefusedWhenPriorIsOff() {
        // No-op: same reason as the symmetric `setOn` case above.
        XCTAssertFalse(LidMutationPolicy.canSet(enabled: false, observedPrior: false))
    }

    func testSetOffRefusedOnUnknownPrior() {
        // B1: unknown prior blocks every mutation — the policy never decides
        // on a base it cannot observe.
        XCTAssertFalse(LidMutationPolicy.canSet(enabled: false, observedPrior: nil))
    }

    // MARK: — Defence-in-depth

    func testPolicyIsDeterministic() {
        // Same facts → same answer (helps catch refactor regressions).
        for prior in [true, false, nil] {
            for enabled in [true, false] {
                let a = LidMutationPolicy.canSet(enabled: enabled, observedPrior: prior)
                let b = LidMutationPolicy.canSet(enabled: enabled, observedPrior: prior)
                XCTAssertEqual(a, b, "policy non-deterministic for prior=\(prior as Any), enabled=\(enabled)")
            }
        }
    }
}
