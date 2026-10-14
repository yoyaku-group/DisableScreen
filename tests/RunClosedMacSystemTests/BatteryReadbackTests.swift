import XCTest
@testable import RunClosedMacSystem

/// Pure parser tests for the IOKit power-source descriptions (ADR 022).
/// Dictionaries mirror `IOPSGetPowerSourceDescription` output on an Apple
/// Silicon MacBook (Max Capacity = 100, Time to Empty in minutes, -1 while
/// estimating).
final class BatteryReadbackTests: XCTestCase {

    private func battery(
        state: String = "Battery Power", current: Any = 41, max: Any = 100,
        timeToEmpty: Any? = 34, charging: Bool = false, present: Bool = true
    ) -> [String: Any] {
        var d: [String: Any] = [
            "Type": "InternalBattery",
            "Is Present": present,
            "Power Source State": state,
            "Current Capacity": current,
            "Max Capacity": max,
            "Is Charging": charging,
            "Name": "InternalBattery-0",
        ]
        if let t = timeToEmpty { d["Time to Empty"] = t }
        return d
    }

    func testOnBatteryReading() {
        let s = BatteryReadback.parse(providingType: "Battery Power", sources: [battery()])
        XCTAssertEqual(s.onBattery, true)
        XCTAssertEqual(s.chargePercent, 41)
        XCTAssertEqual(s.minutesRemaining, 34)
        XCTAssertEqual(s.isCharging, false)
        XCTAssertTrue(s.batteryPresent)
    }

    func testACReading() {
        let s = BatteryReadback.parse(
            providingType: "AC Power",
            sources: [battery(state: "AC Power", current: 12, timeToEmpty: 0, charging: true)])
        XCTAssertEqual(s.onBattery, false)
        XCTAssertEqual(s.chargePercent, 12)
        XCTAssertNil(s.minutesRemaining, "0/-1 time-to-empty = not a real estimate")
        XCTAssertEqual(s.isCharging, true)
    }

    func testCurrentIsParsed() {
        var d = battery(state: "AC Power", current: 10, timeToEmpty: 0, charging: true)
        d["Current"] = -194
        let s = BatteryReadback.parse(providingType: "AC Power", sources: [d])
        XCTAssertEqual(s.currentMilliamps, -194)
        XCTAssertNil(BatteryReadback.parse(providingType: "AC Power", sources: [battery()]).currentMilliamps)
    }

    func testEstimatingTimeToEmptyIsUnknown() {
        let s = BatteryReadback.parse(providingType: "Battery Power",
                                      sources: [battery(timeToEmpty: -1)])
        XCTAssertNil(s.minutesRemaining)
        XCTAssertEqual(s.onBattery, true)
    }

    func testMissingTimeToEmptyIsUnknown() {
        let s = BatteryReadback.parse(providingType: "Battery Power",
                                      sources: [battery(timeToEmpty: nil)])
        XCTAssertNil(s.minutesRemaining)
    }

    func testRawCapacityIsConvertedToPercent() {
        // Some models report raw mAh capacities instead of a 0–100 scale.
        let s = BatteryReadback.parse(providingType: "Battery Power",
                                      sources: [battery(current: 900, max: 6000)])
        XCTAssertEqual(s.chargePercent, 15)
    }

    func testNSNumberValuesAreAccepted() {
        let s = BatteryReadback.parse(
            providingType: "Battery Power",
            sources: [battery(current: NSNumber(value: 9), max: NSNumber(value: 100),
                              timeToEmpty: NSNumber(value: 8))])
        XCTAssertEqual(s.chargePercent, 9)
        XCTAssertEqual(s.minutesRemaining, 8)
    }

    func testZeroMaxCapacityGivesUnknownPercent() {
        let s = BatteryReadback.parse(providingType: "Battery Power",
                                      sources: [battery(max: 0)])
        XCTAssertNil(s.chargePercent)
        XCTAssertEqual(s.onBattery, true)
    }

    func testUnknownStateIsNotCoercedToAC() {
        let s = BatteryReadback.parse(providingType: nil,
                                      sources: [battery(state: "Off Line")])
        XCTAssertNil(s.onBattery, "UNKNOWN ≠ AC (ADR 009)")
    }

    func testDesktopWithoutBatteryFallsBackToProvidingType() {
        let s = BatteryReadback.parse(providingType: "AC Power", sources: [])
        XCTAssertEqual(s.onBattery, false)
        XCTAssertNil(s.chargePercent)
        XCTAssertFalse(s.batteryPresent)
    }

    func testAbsentBatteryEntryIsIgnored() {
        let s = BatteryReadback.parse(providingType: "AC Power",
                                      sources: [battery(present: false)])
        XCTAssertFalse(s.batteryPresent)
        XCTAssertEqual(s.onBattery, false)
    }

    func testNothingAtAllIsUnknown() {
        let s = BatteryReadback.parse(providingType: nil, sources: [])
        XCTAssertNil(s.onBattery)
        XCTAssertNil(s.chargePercent)
    }

    func testLiveReadDoesNotCrash() {
        // Smoke only: the live IOKit read is read-only and must be nil-safe
        // on any host (CI desktop, laptop on AC, laptop on battery).
        let s = BatteryReadback.read()
        if let pct = s.chargePercent {
            XCTAssertTrue((0...100).contains(pct))
        }
    }
}
