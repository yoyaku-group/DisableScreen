import Foundation

/// Deterministic, UI-free reducer for keep-awake leases (ADR 002/004). All time
/// and boot identity come from an injected Clock so this is fully testable.
///
/// Invariants enforced here:
///  - 6: a lease has an owner + stable id + a bounded, monotonic, per-boot deadline.
///  - acquisition is idempotent: renewing an existing (owner, sessionID) updates it
///        in place, it never creates a second lease.
///  - a lease from another boot is never honoured (stale) — it is dropped.
///  - 8: releasing the last lease frees OUR request; it does not force sleep.
public struct LeaseEngine: Sendable {
    public private(set) var leases: [Lease]
    public init(leases: [Lease] = []) { self.leases = leases }

    /// Idempotent acquire/renew. Keyed by (owner, sessionID).
    public mutating func acquire(owner: String, sessionID: String, pid: Int32?,
                                 workSource: WorkSource, idleSleep: Bool, closedLid: Bool,
                                 ttl: Double, clock: Clock) -> Lease {
        let deadline = clock.nowMonotonic + ttl
        if let idx = leases.firstIndex(where: { $0.owner == owner && $0.sessionID == sessionID }) {
            leases[idx].deadlineMonotonic = deadline
            leases[idx].pid = pid
            leases[idx].workSource = workSource
            leases[idx].requestedIdleSleep = idleSleep
            leases[idx].requestedClosedLid = closedLid
            leases[idx].bootID = clock.bootID
            return leases[idx]
        }
        let lease = Lease(id: UUID().uuidString, owner: owner, sessionID: sessionID, pid: pid,
                          bootID: clock.bootID, workSource: workSource, state: .working,
                          requestedIdleSleep: idleSleep, requestedClosedLid: closedLid,
                          deadlineMonotonic: deadline)
        leases.append(lease)
        return lease
    }

    /// Drop expired leases and leases from a different boot. Returns removed count.
    @discardableResult
    public mutating func reap(clock: Clock) -> Int {
        let before = leases.count
        leases.removeAll { $0.bootID != clock.bootID || $0.deadlineMonotonic <= clock.nowMonotonic }
        return before - leases.count
    }

    public mutating func release(owner: String, sessionID: String) {
        leases.removeAll { $0.owner == owner && $0.sessionID == sessionID }
    }

    public mutating func setState(owner: String, sessionID: String, _ state: WorkState) {
        if let idx = leases.firstIndex(where: { $0.owner == owner && $0.sessionID == sessionID }) {
            leases[idx].state = state
        }
    }

    /// Decide whether to keep the machine awake. Only live, this-boot leases in a
    /// state that actually needs the Mac count. `waitingForUser` keeps awake only
    /// within its bounded deadline (handled by reap); `completed`/`failed` do not.
    public func decide(clock: Clock) -> PolicyDecision {
        let live = leases.filter {
            $0.bootID == clock.bootID && $0.deadlineMonotonic > clock.nowMonotonic
            && ($0.state == .working || $0.state == .waitingForUser)
        }
        if live.isEmpty {
            return PolicyDecision(keepAwake: false, reason: "no live work lease")
        }
        return PolicyDecision(keepAwake: true, reason: "\(live.count) live lease(s)")
    }
}

/// Pure display-policy helper (invariant 4): refuse deactivating the only active
/// display. Kept UI-free so it is unit-testable without a screen.
public enum DisplayPolicy {
    public static func canDeactivate(target: UInt32, activeIDs: [UInt32]) -> Bool {
        guard activeIDs.contains(target) else { return false }   // stale target
        return activeIDs.count > 1                                // never the last one
    }
}
