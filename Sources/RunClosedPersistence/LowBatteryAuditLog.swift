import Foundation

/// Append-only audit trail of every low-battery guard mutation (ADR 022):
/// release, emergency release of a stale own record, re-arm, and their
/// failures. One JSON object per line in
/// `~/Library/Application Support/RunClosed/low_battery_audit.jsonl`.
///
/// Each line is one `write(2)` on an `O_APPEND` descriptor, so concurrent
/// writers (app tick, a CLI) append whole lines. Best effort: an audit
/// failure never blocks the protective action — the guard must still
/// release and sleep.
public struct LowBatteryAuditLog: Sendable {
    public let url: URL

    public init() {
        self.url = JSONLAuditLog(fileName: "low_battery_audit.jsonl").url
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

    /// The append mechanics live in `JSONLAuditLog` since ADR 025 — one copy of
    /// the `O_APPEND` / short-write discipline for every audit trail. The file
    /// this type writes keeps its exact format: same keys, same sorted order,
    /// same one-object-per-line layout.
    private var sink: JSONLAuditLog { JSONLAuditLog(url: url) }

    public struct Entry: Codable, Equatable, Sendable {
        public var ts: String
        public var bootID: String
        /// Policy reason (`criticalOwned`, `emergencyStaleOwnership`, `rearmAfterRecovery`…).
        public var reason: String
        /// Mutation outcome (`released`, `releaseFailed`, `rearmed`…).
        public var outcome: String
        public var chargePercent: Int?
        public var minutesRemaining: Int?
        /// Boot that wrote the ownership record — differs from `bootID` on
        /// an emergency release of a stale record.
        public var recordBootID: String?
        public var error: String?
        public var sleepRC: Int32?

        public init(ts: String, bootID: String, reason: String, outcome: String,
                    chargePercent: Int?, minutesRemaining: Int?, recordBootID: String?,
                    error: String?, sleepRC: Int32?) {
            self.ts = ts
            self.bootID = bootID
            self.reason = reason
            self.outcome = outcome
            self.chargePercent = chargePercent
            self.minutesRemaining = minutesRemaining
            self.recordBootID = recordBootID
            self.error = error
            self.sleepRC = sleepRC
        }
    }

    public func append(_ entry: Entry) {
        sink.append(entry)
    }

    /// All entries, oldest first (tests, CLI). Unparseable lines are skipped.
    public func load() -> [Entry] {
        sink.load(Entry.self)
    }
}
