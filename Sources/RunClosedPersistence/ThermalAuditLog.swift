import Foundation

/// Append-only audit trail of every thermal guard action (ADR 025): the heat
/// releases, and the refusals that stopped one.
///
/// One JSON object per line in
/// `~/Library/Application Support/RunClosed/thermal_audit.jsonl` — the shared
/// state directory, **not** `~/Library/Logs/RunClosed/`, which holds the
/// launchd-captured stderr of the ADR 024 agent.
///
/// It shares `JSONLAuditLog`'s mechanics with the battery trail (one
/// `write(2)` per line on an `O_APPEND` descriptor, sorted keys, best-effort so
/// an audit failure never blocks the protective action) but owns its file and
/// its entry shape: a thermal line carries the thermal state and the two
/// enclosure readings, where a battery line carries a charge percentage.
/// Forcing both into one struct would have meant a half-empty record on every
/// line.
///
/// One line per ACTION, never one per minute without effect: a `serious` state
/// that lasts holds the same condition on every tick, so its refusals are
/// deduped by the latch (`warnedSerious` / `warnedCritical`) in
/// `ThermalGuardService`, exactly as the backstop dedupes its repeating
/// failures by key.
public struct ThermalAuditLog: Sendable {
    public let url: URL

    public init() {
        self.url = JSONLAuditLog(fileName: "thermal_audit.jsonl").url
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

    private var sink: JSONLAuditLog { JSONLAuditLog(url: url) }

    public struct Entry: Codable, Equatable, Sendable {
        public var ts: String
        public var bootID: String
        /// Policy reason (`criticalOwned`, `seriousSustained`, `notOwned`…).
        public var reason: String
        /// Mutation outcome (`released`, `releaseFailed`, `releaseRefused`).
        public var outcome: String
        public var thermalState: String
        /// `closed` / `open` / `unknown` — the raw observation, so a later
        /// reading of the log can tell "we refused because the lid was open"
        /// from "we refused because we could not tell".
        public var lid: String
        public var externalDisplay: String
        public var ownership: String
        /// Boot that wrote the ownership record.
        public var recordBootID: String?
        public var error: String?
        public var sleepRC: Int32?

        public init(ts: String, bootID: String, reason: String, outcome: String,
                    thermalState: String, lid: String, externalDisplay: String,
                    ownership: String, recordBootID: String?, error: String?,
                    sleepRC: Int32?) {
            self.ts = ts
            self.bootID = bootID
            self.reason = reason
            self.outcome = outcome
            self.thermalState = thermalState
            self.lid = lid
            self.externalDisplay = externalDisplay
            self.ownership = ownership
            self.recordBootID = recordBootID
            self.error = error
            self.sleepRC = sleepRC
        }
    }

    public func append(_ entry: Entry) { sink.append(entry) }

    /// All entries, oldest first (tests, CLI). Unparseable lines are skipped.
    public func load() -> [Entry] { sink.load(Entry.self) }
}
