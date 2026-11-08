import Foundation
import RunClosedPersistence

/// Pausing and resuming the noisy apps by signal, with the identity discipline
/// ADR 026 requires.
///
/// The rules this type exists to enforce:
///
/// - **A pid is not an identity.** The kernel recycles pids, so "pid 4711 is
///   stopped" is meaningless a few minutes later. Identity is the TRIPLE
///   (pid, process start time, boot session) — three values that together
///   cannot survive a recycling.
/// - **A stop is confirmed by readback**, never by "kill() returned 0".
///   `kill(2)` returning 0 means the signal was delivered, not that the process
///   is stopped.
/// - **A resume requires the identity to be re-proved.** A process whose
///   identity is not proved stays stopped and is reported as "to verify":
///   resuming the wrong process because a pid was recycled is strictly worse
///   than leaving an app paused.
/// - **A process we did not stop is never resumed.** The journal is the only
///   authority, so an app the operator paused themselves is untouched.
public protocol ProcessPauseBackend: Sendable {
    /// Every process matching one of `appNames`, with its identity.
    ///
    /// Returns `nil` when the enumeration FAILED — deliberately distinct from
    /// an empty array, which means "nothing matched". Collapsing the two let a
    /// failed enumeration report the pause as applied.
    func runningProcesses(matching appNames: [String]) -> [RunningProcess]?

    /// The identity currently behind `pid`, or `nil` when no such process
    /// exists. Used to re-prove identity before a resume.
    func identity(ofPid pid: Int32) -> LidCloseActionJournal.ProcessIdentity?

    /// `SIGSTOP`. Returns whether the signal was DELIVERED; the caller reads
    /// back to confirm the state.
    @discardableResult
    func stop(pid: Int32) -> Bool

    /// `SIGCONT`. Returns whether the signal was DELIVERED.
    @discardableResult
    func resume(pid: Int32) -> Bool

    /// Is the process stopped right now? Tri-state, `nil` = unreadable.
    func isStopped(pid: Int32) -> Bool?
}

/// One live process, as the backend found it.
public struct RunningProcess: Equatable, Sendable {
    public var pid: Int32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public var path: String
    public var appName: String

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64,
                path: String, appName: String) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.path = path
        self.appName = appName
    }

    public func journalEntry(bootID: String) -> LidCloseActionJournal.StoppedProcess {
        LidCloseActionJournal.StoppedProcess(
            pid: pid, startSeconds: startSeconds, startMicroseconds: startMicroseconds,
            bootID: bootID, path: path, appName: appName)
    }
}

/// Live libproc backend.
///
/// `proc_listallpids` + `proc_pidinfo(PROC_PIDTBSDINFO)` for identity and state,
/// `proc_pidpath` for the executable path, and `kill(2)` for the signals. All
/// public API; no privilege (a process may always signal its OWN processes, and
/// these are all the same user's).
public struct LibprocPauseBackend: ProcessPauseBackend {

    /// The boot this backend reports identities on. A start time is only
    /// comparable within one boot session, so the value travels with the
    /// identity rather than being re-read at compare time.
    public let bootID: String

    public init(bootID: String = BootID.current()) {
        self.bootID = bootID
    }

    /// Bundle-prefix segments that identify each default app in an executable
    /// path. macOS keeps apps under `…/Foo.app/Contents/MacOS/Foo`, and helper
    /// processes under `…/Foo.app/Contents/Frameworks/…`, so matching the
    /// `Foo.app` COMPONENT catches the main process and its children while
    /// never matching an unrelated binary that merely contains the word.
    static func matches(path: String, appName: String) -> Bool {
        let component = "\(appName).app"
        return path.split(separator: "/").contains { $0 == component }
    }

    public func runningProcesses(matching appNames: [String]) -> [RunningProcess]? {
        guard !appNames.isEmpty else { return [] }
        guard let pids = Self.allPids() else { return nil }
        var out: [RunningProcess] = []
        var sawMatchingButUnreadable = false
        for pid in pids {
            guard let snap = Self.snapshot(pid: pid) else { continue }
            // An app the OPERATOR already suspended is never adopted. Pausing
            // it would journal it as ours, and the undo would then `SIGCONT`
            // an app the operator had deliberately stopped — an effect they
            // never asked for (caught by ai-review-gate). Only a process we
            // can observe RUNNING is a candidate.
            guard snap.status != Self.stoppedStatus else { continue }
            // A path we cannot read does not tell us whether this process is a
            // target. That is a real gap ONLY if it could have been one, which
            // we cannot know — but tainting on every unreadable SYSTEM process
            // disabled app suspension entirely on every tick (gate finding, `An
            // unrelated unreadable process aborts all app suspension`). So the
            // gap is recorded only while nothing has matched yet: if the run
            // found its targets and simply could not read some unrelated pid,
            // the pause proceeds.
            // Record the gap WITHOUT consulting `out` here: doing that made the
            // result depend on the ORDER pids came back in (gate finding, `An
            // unrelated unreadable process can prevent all app suspension` was
            // the same defect seen from the other side). The decision is made
            // once, after the loop.
            guard let path = Self.path(ofPid: pid) else {
                sawMatchingButUnreadable = true
                continue
            }
            guard let name = appNames.first(where: { Self.matches(path: path, appName: $0) })
            else { continue }
            out.append(RunningProcess(
                pid: snap.pid, startSeconds: snap.startSeconds,
                startMicroseconds: snap.startMicroseconds, path: path, appName: name))
        }
        // A per-process read failure is NOT proof that nothing matched: report
        // it as unreadable so the service says so instead of `.applied`.
        // ANY unreadable candidate taints the result, not only an all-empty one:
        // with two targets, one readable and one not, returning just the
        // readable one let the service stop a SUBSET and report `.applied`
        // while the other app kept running (gate finding, `Partial enumeration
        // failures are reported as complete success`).
        // ONLY an empty result is ambiguous: no target matched, and some
        // process was unreadable, so the unreadable one may have been the
        // target. With at least one real match the run is useful — pausing it
        // beats pausing nothing because some unrelated system process cannot be
        // read. Order-independent by construction.
        if out.isEmpty, sawMatchingButUnreadable { return nil }
        return out
    }

    public func identity(ofPid pid: Int32) -> LidCloseActionJournal.ProcessIdentity? {
        guard let snap = Self.snapshot(pid: pid) else { return nil }
        return LidCloseActionJournal.ProcessIdentity(
            pid: snap.pid, startSeconds: snap.startSeconds,
            startMicroseconds: snap.startMicroseconds, bootID: bootID)
    }

    @discardableResult
    public func stop(pid: Int32) -> Bool {
        kill(pid, SIGSTOP) == 0
    }

    @discardableResult
    public func resume(pid: Int32) -> Bool {
        kill(pid, SIGCONT) == 0
    }

    public func isStopped(pid: Int32) -> Bool? {
        guard let snap = Self.snapshot(pid: pid) else { return nil }
        return snap.status == UInt32(SSTOP)
    }

    // MARK: — libproc plumbing

    struct Snapshot: Equatable {
        var pid: Int32
        var startSeconds: UInt64
        var startMicroseconds: UInt64
        var status: UInt32
    }

    /// `true` when the kernel reports the process as stopped.
    public static let stoppedStatus = UInt32(SSTOP)

    /// `nil` = the enumeration FAILED, which is NOT the same as "no processes".
    ///
    /// Collapsing both to `[]` made a failed enumeration look like "no matching
    /// apps", so the service reported the pause as applied while the apps were
    /// still running (gate finding, `Process enumeration failure becomes
    /// successful pause`).
    static func allPids() -> [Int32]? {
        // The count can grow between the two calls; a slightly larger buffer
        // than reported costs nothing and avoids a second round trip.
        let hint = proc_listallpids(nil, 0)
        guard hint > 0 else { return nil }
        var capacity = Int(hint) + 64
        while capacity <= 1 << 20 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let n = proc_listallpids(&buffer, Int32(capacity * MemoryLayout<pid_t>.size))
            if n <= 0 { return nil }
            if Int(n) < capacity { return buffer.prefix(Int(n)).filter { $0 > 0 } }
            // Filled the buffer: another 64 and retry, bounded.
            capacity *= 2
        }
        return nil
    }

    static func snapshot(pid: Int32) -> Snapshot? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard rc == size else { return nil }
        return Snapshot(pid: pid,
                        startSeconds: UInt64(info.pbi_start_tvsec),
                        startMicroseconds: UInt64(info.pbi_start_tvusec),
                        status: UInt32(info.pbi_status))
    }

    static func path(ofPid pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        // `n` counts the bytes written INCLUDING the trailing NUL.
        let bytes = buffer.prefix(Int(n)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.isEmpty ? nil : path
    }
}
