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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("low_battery_audit.jsonl")
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        let fd = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) }
    }

    /// All entries, oldest first (tests, CLI). Unparseable lines are skipped.
    public func load() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(Entry.self, from: Data($0.utf8))
        }
    }
}
