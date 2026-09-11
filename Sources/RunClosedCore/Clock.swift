import Foundation

/// Injectable clock + boot identity (ADR 002). Deadlines are monotonic and scoped
/// to one boot; a boot change invalidates them. Tests inject a FakeClock.
public protocol Clock: Sendable {
    var nowMonotonic: Double { get }   // seconds, monotonically increasing
    var bootID: String { get }
}

/// Real clock: monotonic time from uptime, boot id from the host.
public struct SystemClock: Clock {
    public let bootID: String
    public init(bootID: String) { self.bootID = bootID }
    public var nowMonotonic: Double {
        // Monotonic even across wall-clock changes; not affected by NTP.
        ProcessInfo.processInfo.systemUptime
    }
}
