import Foundation

/// Cross-process advisory lock serialising every writer of the lid flag and
/// its records (ADR 022): the menu-bar guard tick, the popup switch and the
/// CLI `lid-stay-awake on|off`. Without it a guard re-arm in flight could
/// land after an operator OFF and undo it, or a tick could save a latch
/// loaded before an operator cleared it (lost update).
///
/// `flock(2)` on `~/Library/Application Support/RunClosed/lid.lock`; the lock
/// dies with the process, so a crash never leaves it held. If the lock file
/// cannot be opened the body still runs: this is a race guard, not a safety
/// gate — B1/B2 and the readback stay authoritative inside the body.
public struct LidWriteLock: Sendable {
    public let url: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("lid.lock")
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { return try body() }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
