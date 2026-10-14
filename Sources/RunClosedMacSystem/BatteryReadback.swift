import Foundation
import IOKit.ps

/// One read-only observation of the power source (ADR 022). Every field is
/// optional: UNKNOWN is never coerced to a value (ADR 009 — a missing
/// reading must not look like "on AC" or "full").
public struct BatteryState: Equatable, Sendable {
    /// `true` on battery, `false` on AC, `nil` unknown.
    public var onBattery: Bool?
    public var chargePercent: Int?
    /// Minutes to empty; `nil` while macOS is still estimating (-1) or on AC.
    public var minutesRemaining: Int?
    public var isCharging: Bool?
    /// Whether an internal battery was found at all (desktop Macs: false).
    public var batteryPresent: Bool

    public init(onBattery: Bool?, chargePercent: Int?, minutesRemaining: Int?,
                isCharging: Bool?, batteryPresent: Bool) {
        self.onBattery = onBattery
        self.chargePercent = chargePercent
        self.minutesRemaining = minutesRemaining
        self.isCharging = isCharging
        self.batteryPresent = batteryPresent
    }

    public static let unknown = BatteryState(
        onBattery: nil, chargePercent: nil, minutesRemaining: nil,
        isCharging: nil, batteryPresent: false)
}

/// Read-only battery readback through the public IOKit power-sources API
/// (`IOPSCopyPowerSourcesInfo` / `IOPSGetPowerSourceDescription`). No
/// subprocess, no privilege, no mutation — modelled on `PowerReadback`.
public enum BatteryReadback {

    /// Live read. Returns `.unknown` if IOKit gives nothing back.
    public static func read() -> BatteryState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unknown
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var descriptions: [[String: Any]] = []
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                if let desc = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] {
                    descriptions.append(desc)
                }
            }
        }
        return parse(providingType: providing, sources: descriptions)
    }

    // IOPSKeys.h string values (the C macros), spelled out so the parser is
    // pure and testable with plain dictionaries.
    static let typeKey = "Type"                     // kIOPSTypeKey
    static let internalBattery = "InternalBattery"  // kIOPSInternalBatteryType
    static let presentKey = "Is Present"            // kIOPSIsPresentKey
    static let stateKey = "Power Source State"      // kIOPSPowerSourceStateKey
    static let acPower = "AC Power"                 // kIOPSACPowerValue
    static let batteryPower = "Battery Power"       // kIOPSBatteryPowerValue
    static let upsPower = "UPS Power"               // kIOPSUPSType providing value
    static let currentCapacityKey = "Current Capacity"  // kIOPSCurrentCapacityKey
    static let maxCapacityKey = "Max Capacity"          // kIOPSMaxCapacityKey
    static let timeToEmptyKey = "Time to Empty"         // kIOPSTimeToEmptyKey
    static let isChargingKey = "Is Charging"            // kIOPSIsChargingKey

    /// Pure parser — unit-tested with injected dictionaries.
    ///
    /// - Internal battery present: its own `Power Source State` decides
    ///   on-battery vs AC; percent = current / max × 100 (max is 100 on
    ///   Apple Silicon, but a raw-mAh max is handled too); `Time to Empty`
    ///   ≤ 0 (−1 = still estimating) → `nil`.
    /// - No internal battery (desktop): fall back to the providing source
    ///   type; percent/minutes stay unknown.
    static func parse(providingType: String?, sources: [[String: Any]]) -> BatteryState {
        let battery = sources.first { desc in
            (desc[typeKey] as? String) == internalBattery
                && ((desc[presentKey] as? Bool) ?? true)
        }
        guard let desc = battery else {
            return BatteryState(
                onBattery: onBattery(fromState: providingType),
                chargePercent: nil,
                minutesRemaining: nil,
                isCharging: nil,
                batteryPresent: false)
        }
        let state = (desc[stateKey] as? String) ?? providingType
        var percent: Int?
        if let cur = intValue(desc[currentCapacityKey]),
           let max = intValue(desc[maxCapacityKey]), max > 0, cur >= 0 {
            percent = Int((Double(cur) / Double(max) * 100).rounded())
            percent = Swift.min(100, percent!)
        }
        var minutes: Int?
        if let tte = intValue(desc[timeToEmptyKey]), tte > 0 {
            minutes = tte
        }
        return BatteryState(
            onBattery: onBattery(fromState: state),
            chargePercent: percent,
            minutesRemaining: minutes,
            isCharging: desc[isChargingKey] as? Bool,
            batteryPresent: true)
    }

    static func onBattery(fromState state: String?) -> Bool? {
        switch state {
        case acPower?: return false
        case batteryPower?, upsPower?: return true
        default: return nil
        }
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
