import Foundation

/// Append-only audit trail of the out-of-app recovery backstop (ADR 024).
/// One JSON object per line in
/// `~/Library/Application Support/RunClosed/recovery_audit.jsonl`.
///
/// Written ONLY when the backstop acted or failed — never on a minute that
/// found nothing to do. The agent runs every 60 s, so a line per no-op would be
/// 1 440 lines a day saying nothing.
///
/// Same discipline as `LowBatteryAuditLog`: each line is one `write(2)` on an
/// `O_APPEND` descriptor so concurrent writers (the app, a CLI) append whole
/// lines, and an audit failure never blocks the protective action.
public struct RecoveryAuditLog: Sendable {
    public let url: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("recovery_audit.jsonl")
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var ts: String
        public var bootID: String
        /// Which protective step this line is about: `sessionExpiry`,
        /// `sessionReconcile`, `batteryRelease`, `sleep`.
        public var step: String
        /// Terminal outcome of that step (`released`, `flagLeftOn`,
        /// `releaseFailed`, `cleared`, `rearmedWithheld`, `refused`…).
        public var outcome: String
        /// Why, in the policy's own vocabulary (`criticalOwned`,
        /// `emergencyStaleOwnership`, `wallDeadline`…).
        public var reason: String?
        /// Extra context for a human reading the line (`due`, `notDue`…).
        public var detail: String?
        public var chargePercent: Int?
        public var minutesRemaining: Int?
        /// Boot that wrote the ownership record — differs from `bootID` on a
        /// release of our record left by a previous boot.
        public var recordBootID: String?
        public var error: String?
        public var sleepRC: Int32?

        public init(ts: String, bootID: String, step: String, outcome: String,
                    reason: String? = nil, detail: String? = nil,
                    chargePercent: Int? = nil, minutesRemaining: Int? = nil,
                    recordBootID: String? = nil, error: String? = nil,
                    sleepRC: Int32? = nil) {
            self.ts = ts
            self.bootID = bootID
            self.step = step
            self.outcome = outcome
            self.reason = reason
            self.detail = detail
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
            try? decoder.decode(Entry.self, from: data($0))
        }
    }

    private func data(_ line: Substring) -> Data { Data(line.utf8) }
}
