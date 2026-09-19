import XCTest
@testable import RunClosedCore

/// Pure-policy tests for the display-mutation guard. No AppKit, no CoreGraphics,
/// no filesystem — exercises only the boolean gates.
final class DisplayMutationPolicyTests: XCTestCase {

    func testDisableAllowedOnMultiDisplayTopology() {
        let active: [UInt32] = [1, 2, 3]
        XCTAssertTrue(DisplayMutationPolicy.canDisable(target: 1, activeIDs: active))
        XCTAssertTrue(DisplayMutationPolicy.canDisable(target: 3, activeIDs: active))
    }

    func testDisableRefusedOnLastActiveDisplay() {
        let active: [UInt32] = [42]
        XCTAssertFalse(DisplayMutationPolicy.canDisable(target: 42, activeIDs: active),
                       "invariant 4: never disable the last active display")
    }

    func testDisableRefusedOnStaleTargetNotInActiveSet() {
        let active: [UInt32] = [1, 2]
        XCTAssertFalse(DisplayMutationPolicy.canDisable(target: 99, activeIDs: active),
                       "stale target: id is not currently active")
    }

    func testDisableOnEmptyActiveSetAlwaysRefused() {
        // Pathological case: no active displays at all → refuse even if target
        // matched (it can't — but defensively).
        XCTAssertFalse(DisplayMutationPolicy.canDisable(target: 1, activeIDs: []))
    }

    func testEnableAllowsKnownTargets() {
        let known: [UInt32] = [10, 20, 30]
        XCTAssertTrue(DisplayMutationPolicy.canEnable(target: 10, knownIDs: known))
        XCTAssertTrue(DisplayMutationPolicy.canEnable(target: 30, knownIDs: known))
    }

    func testEnableRefusesUnknownTargets() {
        let known: [UInt32] = [10, 20]
        XCTAssertFalse(DisplayMutationPolicy.canEnable(target: 999, knownIDs: known))
    }
}
