import Foundation

/// Proof that the recovery backstop actually RUNS (ADR 024).
///
/// `SMAppService.agent(plistName:)` reporting `enabled` says the agent is
/// registered and approved — it does NOT say a single protective minute ever
/// executed. An approved agent whose `BundleProgram` does not resolve, or whose
/// binary was removed from the bundle, still reads `enabled`. Relaxing the CLI's
/// "something would end this session" refusal on that alone would let a timed
/// session start with nothing enforcing it — the exact silent failure ADR 023
/// refuses.
///
/// So `recover --backstop` writes this record at the END of every run, whatever
/// the outcome (`nothingToDo`, `appAlive`, `busy`, `completed`), and the CLI
/// requires a FRESH one on the current boot before it treats the agent as an
/// enforcer.
///
/// Same discipline as the other stores: one module owns the layout, `.atomic`
/// writes, a missing or corrupt file reads as "no proof" (B3: never claim an
/// obligation we cannot prove). The write is a single small file and happens
/// outside the lock, so the fast path stays free of `pmset` and of
/// `LidWriteLock`.
///
/// Format on disk (`~/Library/Application Support/RunClosed/backstop_heartbeat.json`):
/// ```
/// {
///   "schemaVersion": 1,
///   "at": "<ISO-8601, wall clock>",
///   "bootID": "<boot session uuid>",
///   "exitCode": 0,
///   "rearmWithheldReported": false
/// }
/// ```
public struct BackstopHeartbeatStore {
    public let url: URL

    /// Canonical path. Creates the parent directory if needed (idempotent).
    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("backstop_heartbeat.json")
    }

    /// Test seam: explicit URL. Does NOT create the parent directory — tests
    /// own their temp tree, and a typo must not silently succeed.
    public init(url: URL) {
        self.url = url
    }

    /// One backstop run.
    public struct Record: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        /// When the run finished (wall clock).
        public var at: Date
        /// The boot it ran on. A heartbeat from another boot proves nothing
        /// about whether the agent will fire on THIS one.
        public var bootID: String
        public var exitCode: Int32
        /// Whether the current `rearmWithheld` episode has already been
        /// audited (ADR 024 review round 2 — the condition holds for every
        /// minute while it lasts, so auditing it each time floods the log).
        public var rearmWithheldReported: Bool
        /// The identifier of the last REPEATING failure already audited (a
        /// battery release that keeps failing for the same reason). Same
        /// once-per-episode discipline as `rearmWithheldReported`: a stale
        /// sudoers rule holds the condition every 60 s, and 1 440 identical
        /// audit lines a day is the flood the rule exists to stop (round 9).
        public var lastAuditedFailureKey: String?
        /// The same dedupe, for a SESSION expiry whose deadline cannot be
        /// enforced. `.retained` keeps the record precisely so the next minute
        /// retries, so a release that keeps failing writes the same line 1 440
        /// times a day — the same flood, from the other step (review round 15).
        /// Kept apart from `lastAuditedFailureKey` because the two steps audit
        /// independently: a battery failure must not suppress a session one.
        public var lastAuditedSessionFailureKey: String?
        public init(schemaVersion: Int = kBackstopHeartbeatSchemaVersion,
                    at: Date,
                    bootID: String,
                    exitCode: Int32,
                    rearmWithheldReported: Bool = false,
                    lastAuditedFailureKey: String? = nil,
                    lastAuditedSessionFailureKey: String? = nil) {
            self.schemaVersion = schemaVersion
            self.at = at
            self.bootID = bootID
            self.exitCode = exitCode
            self.rearmWithheldReported = rearmWithheldReported
            self.lastAuditedFailureKey = lastAuditedFailureKey
            self.lastAuditedSessionFailureKey = lastAuditedSessionFailureKey
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, at, bootID, exitCode, rearmWithheldReported,
                 lastAuditedFailureKey, lastAuditedSessionFailureKey
        }

        /// Tolerant decoding: a key a later version adds must not make the file
        /// read as corrupt and lose the proof it carries.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? kBackstopHeartbeatSchemaVersion
            at = try c.decode(Date.self, forKey: .at)
            bootID = try c.decode(String.self, forKey: .bootID)
            exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode) ?? 0
            rearmWithheldReported = try c.decodeIfPresent(
                Bool.self, forKey: .rearmWithheldReported) ?? false
            lastAuditedFailureKey = try c.decodeIfPresent(
                String.self, forKey: .lastAuditedFailureKey)
            lastAuditedSessionFailureKey = try c.decodeIfPresent(
                String.self, forKey: .lastAuditedSessionFailureKey)
        }
    }

    /// The record in the shape `RecoveryPolicy.runFreshness` grades.
    ///
    /// One projection for every caller (the CLI's enforcer check, its
    /// `status`/`doctor` blocks, and the app's popup row), so a record cannot
    /// be read with one meaning in one place and another elsewhere.
    public func freshnessInput() -> (at: Date, bootID: String, exitCode: Int32)? {
        load().map { (at: $0.at, bootID: $0.bootID, exitCode: $0.exitCode) }
    }

    /// The last run, or nil when the file is absent or unreadable.
    public func load() -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    /// Atomic write (sibling temp file + rename), ISO-8601 dates so the file
    /// stays readable with `jq` and by the CLI.
    @discardableResult
    public func save(_ record: Record) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

public let kBackstopHeartbeatSchemaVersion = 1
