import Foundation

/// Generic append-only JSONL audit trail (ADR 025).
///
/// Extracted from `LowBatteryAuditLog` (ADR 022) so the thermal guard writes its
/// actions through the SAME mechanics instead of a third copy of the same
/// `open`/`write`/`close` dance. The extraction is mechanical on purpose: the
/// encoding options, the permission bits, the append mode and the short-write
/// repair are unchanged, so `low_battery_audit.jsonl` keeps the exact byte
/// format it had before this type existed.
///
/// Contract, inherited from the two logs it replaces/absorbs:
///
/// - ONE JSON object per line, keys sorted, UTF-8, terminated by `\n`.
/// - Each line is one `write(2)` on an `O_APPEND` descriptor, so the app's tick,
///   a CLI process and a launchd agent can all append whole lines.
/// - Best effort: an audit failure never blocks the protective action, because
///   the action matters more than its record. It goes to stderr instead.
public struct JSONLAuditLog: Sendable {
    public let url: URL

    /// Append to an explicit path (tests, and the specific logs that own a
    /// filename).
    public init(url: URL) {
        self.url = url
    }

    /// Append under the shared state directory
    /// (`~/Library/Application Support/RunClosed/`), creating it if needed.
    ///
    /// Deliberately NOT `~/Library/Logs/RunClosed/`: that directory holds the
    /// launchd-captured stderr of the ADR 024 agent. Audit lines are records
    /// the product reads back, so they live with the other stores.
    public init(fileName: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent(fileName)
    }

    public func append<T: Encodable>(_ entry: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(entry) else {
            Self.reportFailure(url: url, reason: "the entry could not be encoded")
            return
        }
        data.append(0x0A)
        let fd = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Self.reportFailure(url: url, reason: "open() failed (errno \(errno))")
            return
        }
        defer { close(fd) }
        let written = data.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) }
        if written != data.count {
            // The trail of protective actions is forensic evidence: a silent
            // drop means a release that really happened leaves no trace, and an
            // investigation later reads "nothing happened".
            Self.reportFailure(url: url, reason: "short write (\(written)/\(data.count) bytes)")
            // A partial write leaves NO trailing newline, so the next append
            // would be glued onto the truncated JSON and destroy that record
            // too — one lost line becomes two, and the second one was fine.
            // Closing the line costs an unparseable stub (skipped on read) and
            // keeps every later record intact (ADR 024 review round 8).
            let newline = Data([0x0A])
            _ = newline.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) }
        }
    }

    /// All entries, oldest first (tests, CLI). Unparseable lines are skipped.
    public func load<T: Decodable>(_ type: T.Type = T.self) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(T.self, from: Data($0.utf8))
        }
    }

    /// stderr, never the audit file itself: a failure to write there must not
    /// recurse into another failing write.
    private static func reportFailure(url: URL, reason: String) {
        FileHandle.standardError.write(Data(
            "[RunClosed] audit append FAILED at \(url.path): \(reason)\n".utf8))
    }
}
