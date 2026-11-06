import Foundation

/// "The menu-bar app is running" as a lock, not a heartbeat (ADR 023).
///
/// The app holds `flock(2)` on `~/Library/Application Support/RunClosed/app.lock`
/// for its whole life; the kernel drops it when the process exits or crashes,
/// so it can never look alive after a crash, and it never looks stale after
/// a sleep the way a timestamp would.
///
/// Today the app is the only thing that enforces a session deadline, so the
/// CLI refuses to start a TIMED session when nobody holds this lock. The L2
/// launchd backstop (ADR 024) reuses it to stay out of the app's way.
///
/// Probing opens a NEW file descriptor: flock locks belong to the open file
/// description, so a probe from the holding process still sees the lock as
/// held (that is what makes it testable in one process). A probe takes a
/// SHARED lock, so two probes running at once (the CLI and the L2
/// backstop) never mistake each other for the app; only the app's
/// exclusive lock reads as held.
public final class AppLivenessLock: @unchecked Sendable {
    public let url: URL
    private var heldFD: Int32 = -1

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("app.lock")
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

    deinit {
        release()
    }

    /// Give the lock up before the process exits. The app calls it in its
    /// quit teardown, inside the lid lock section, so a CLI waiting on that
    /// lock sees the app as gone. Idempotent.
    public func release() {
        guard heldFD >= 0 else { return }
        close(heldFD)
        heldFD = -1
    }

    /// Take the lock for the life of this object (the app keeps it until it
    /// exits). `false` when the file cannot be opened or another process
    /// already holds it (a second app instance), or a probe holds its shared
    /// lock at that instant (the app retries).
    @discardableResult
    public func hold() -> Bool {
        if heldFD >= 0 { return true }
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        heldFD = fd
        return true
    }

    /// Whether some holder (the app) has the lock right now. Non-blocking;
    /// a lock file that cannot be opened reads as "not held", the safe answer
    /// for a caller that refuses when nothing enforces a deadline.
    public func isHeld() -> Bool {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
