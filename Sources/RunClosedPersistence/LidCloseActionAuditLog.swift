import Foundation

/// Append-only audit trail of every lid-close action (ADR 026): the apply, the
/// undo, and every refusal that stopped one.
///
/// One JSON object per line in
/// `~/Library/Application Support/RunClosed/lid_close_audit.jsonl`, through the
/// same `JSONLAuditLog` mechanics as the battery and thermal trails (one
/// `write(2)` per line on an `O_APPEND` descriptor, sorted keys, best effort so
/// an audit failure never blocks the action).
///
/// One line per ACTION, never one per tick: the tick runs every 30 s and the
/// same conditions hold for minutes at a time, so the service dedupes by the
/// episode the journal already carries.
public struct LidCloseActionAuditLog: Sendable {
    public let url: URL

    public init() {
        self.url = JSONLAuditLog(fileName: "lid_close_audit.jsonl").url
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

    private var sink: JSONLAuditLog { JSONLAuditLog(url: url) }

    public struct Entry: Codable, Equatable, Sendable {
        public var ts: String
        public var bootID: String
        /// `applied` / `undone` / `partial` / `failed`.
        public var outcome: String
        /// The policy reason (`applied`, `lidOpen`, `externalDisplay`…).
        public var reason: String
        /// `closed` / `open` / `unknown` — the raw observation, so a later
        /// reading can tell "we refused because the lid was open" from "we
        /// refused because we could not tell".
        public var lid: String
        /// `connected` / `none` / `unknown`.
        public var externalDisplay: String
        /// Whether a keep-awake session was live.
        public var sessionActive: Bool
        /// `muted` / `unmuted` / `none` / `gone` (the device disappeared).
        public var audio: String?
        public var audioDeviceUID: String?
        public var audioError: String?
        /// Pids stopped by this action.
        public var stoppedPids: [Int32]?
        /// Pids resumed by this action.
        public var resumedPids: [Int32]?
        /// Pids whose identity could not be re-proved, left stopped on purpose.
        public var unverifiedPids: [Int32]?
        /// Pids whose `SIGSTOP`/`SIGCONT` failed.
        public var failedPids: [Int32]?
        public var appError: String?

        public init(ts: String, bootID: String, outcome: String, reason: String,
                    lid: String, externalDisplay: String, sessionActive: Bool,
                    audio: String? = nil, audioDeviceUID: String? = nil,
                    audioError: String? = nil, stoppedPids: [Int32]? = nil,
                    resumedPids: [Int32]? = nil, unverifiedPids: [Int32]? = nil,
                    failedPids: [Int32]? = nil, appError: String? = nil) {
            self.ts = ts
            self.bootID = bootID
            self.outcome = outcome
            self.reason = reason
            self.lid = lid
            self.externalDisplay = externalDisplay
            self.sessionActive = sessionActive
            self.audio = audio
            self.audioDeviceUID = audioDeviceUID
            self.audioError = audioError
            self.stoppedPids = stoppedPids
            self.resumedPids = resumedPids
            self.unverifiedPids = unverifiedPids
            self.failedPids = failedPids
            self.appError = appError
        }
    }

    public func append(_ entry: Entry) { sink.append(entry) }

    /// All entries, oldest first (tests, CLI). Unparseable lines are skipped.
    public func load() -> [Entry] { sink.load(Entry.self) }
}
