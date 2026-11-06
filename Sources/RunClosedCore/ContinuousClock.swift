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
        // Split to avoid overflowing UInt64 on a long-lived machine: the
        // seconds part is exact, the remainder is converted on its own.
        let seconds = ticks / denom
        let remainder = ticks % denom
        return seconds * numer + (remainder * numer) / denom
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

    /// Convenience for pure policy: seconds → nanoseconds.
    public static func nanoseconds(fromSeconds s: Double) -> UInt64 {
        guard s > 0 else { return 0 }
        return UInt64((s * 1_000_000_000).rounded())
    }
}
