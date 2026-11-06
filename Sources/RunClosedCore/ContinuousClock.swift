import Foundation

/// Injectable CONTINUOUS clock (ADR 023).
///
/// Why not reuse `Clock`/`SystemClock` (which exposes `systemUptime`)?
/// `systemUptime` — i.e. `mach_absolute_time`, what `ProcessInfo` reports —
/// STOPS while the machine sleeps. A keep-awake session is precisely the case
/// where the Mac closes its lid and sleeps: a deadline measured on that clock
/// would freeze overnight and never come due. `mach_continuous_time` keeps
/// counting through sleep, so "2 h from now" means 2 h of wall time whether or
/// not the machine slept in between.
///
/// Same injectability discipline as `Clock` (ADR 002): tests pin the value,
/// production reads the kernel counter.
public protocol ContinuousClock: Sendable {
    /// Nanoseconds since boot, INCLUDING time spent asleep.
    var nowContinuousNanoseconds: UInt64 { get }
    var bootID: String { get }
}

/// Production clock: `mach_continuous_time()` converted through `mach_timebase_info`.
///
/// The timebase is read once and cached: on every Apple Silicon machine
/// measured it is 1/1 (nanoseconds), on Intel it is 1/1 as well in practice,
/// but the conversion is kept so a host whose counter ticks differently cannot
/// silently shift every deadline by a constant factor.
public struct SystemContinuousClock: ContinuousClock {
    public let bootID: String

    public init(bootID: String) {
        self.bootID = bootID
    }

    public var nowContinuousNanoseconds: UInt64 {
        let ticks = mach_continuous_time()
        let numer = UInt64(ContinuousClockTimebase.numer)
        let denom = UInt64(ContinuousClockTimebase.denom)
        guard denom != 0 else { return ticks }
        // Split so the multiplication cannot overflow on a long-lived machine:
        // the whole seconds are exact, the remainder is converted on its own.
        // The reporting variants keep an absurd timebase from trapping — a
        // saturated reading is a wrong deadline, a trap is a crashed app.
        let seconds = ticks / denom
        let remainder = ticks % denom
        let (whole, wholeOverflowed) = seconds.multipliedReportingOverflow(by: numer)
        guard !wholeOverflowed else { return UInt64.max }
        let (part, partOverflowed) = (remainder * numer).dividedReportingOverflow(by: denom)
        guard !partOverflowed else { return UInt64.max }
        let (total, totalOverflowed) = whole.addingReportingOverflow(part)
        return totalOverflowed ? UInt64.max : total
    }
}

/// `mach_timebase_info` fetched once (it never changes at runtime).
public enum ContinuousClockTimebase {
    public static let (numer, denom): (UInt32, UInt32) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
            return (1, 1)
        }
        return (info.numer, info.denom)
    }()

    /// Convenience for pure policy: nanoseconds → seconds (Double).
    public static func seconds(fromNanoseconds ns: UInt64) -> Double {
        Double(ns) / 1_000_000_000
    }

    /// Upper bound on the conversion: `UInt64.max` nanoseconds is ~584 years,
    /// far past any session, and this keeps the multiplication below in range.
    public static let maxConvertibleNanoseconds = UInt64.max

    /// Convenience for pure policy: seconds → nanoseconds.
    ///
    /// Clamped on purpose. `UInt64(Double)` TRAPS on a negative, NaN or
    /// out-of-range value, so an absurd `--for` argument would crash the CLI
    /// instead of exiting 64. Non-finite input yields 0, and anything past the
    /// representable range saturates — a policy bug then produces a very late
    /// deadline rather than a trap.
    public static func nanoseconds(fromSeconds s: Double) -> UInt64 {
        guard s.isFinite, s > 0 else { return 0 }
        let scaled = (s * 1_000_000_000).rounded()
        guard scaled.isFinite, scaled < Double(maxConvertibleNanoseconds) else {
            return maxConvertibleNanoseconds
        }
        return UInt64(scaled)
    }
}
