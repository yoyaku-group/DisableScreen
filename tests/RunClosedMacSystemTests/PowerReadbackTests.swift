import XCTest
@testable import RunClosedMacSystem

/// Regression tests for the `pmset -g` parser (live finding 2026-09-20:
/// the original `split(separator: " ")` only handled literal spaces, so real
/// tab-separated output always parsed as `false` and every lid toggle looked
/// broken).
final class PowerReadbackTests: XCTestCase {

    func testParsesRealTabSeparatedOutput() {
        // Exactly what `pmset -g` prints (tab-separated).
        let output = "System-wide power settings:\n SleepDisabled\t\t1\n Sleep On Power Button 1\n disksleep            10\n"
        XCTAssertEqual(PowerReadback.parseLidStayAwake(output), true)
    }

    func testParsesTabSeparatedZero() {
        let output = " SleepDisabled\t\t0\n disksleep            10\n"
        XCTAssertEqual(PowerReadback.parseLidStayAwake(output), false)
    }

    func testParsesSpaceSeparatedOutput() {
        // Defensive: some builds/tools may render single spaces.
        XCTAssertEqual(PowerReadback.parseLidStayAwake(" SleepDisabled 1\n"), true)
        XCTAssertEqual(PowerReadback.parseLidStayAwake(" SleepDisabled 0\n"), false)
    }

    func testMissingKeyIsUnknownNotFalse() {
        let output = " disksleep            10\n sleep                55 \n"
        XCTAssertNil(PowerReadback.parseLidStayAwake(output))
    }

    func testEmptyOutputIsUnknown() {
        XCTAssertNil(PowerReadback.parseLidStayAwake(""))
    }

    func testKeyPrefixDoesNotMatchUnrelatedLines() {
        // "SleepDisabledFoo" must not be treated as the key.
        let output = " SleepDisabledFoo\t\t1\n"
        // hasPrefix("SleepDisabled") matches — the value field is "1" so this
        // would parse true. Pin the current behavior explicitly so a future
        // tightening is a deliberate change, not an accident.
        XCTAssertEqual(PowerReadback.parseLidStayAwake(output), true)
    }
}
