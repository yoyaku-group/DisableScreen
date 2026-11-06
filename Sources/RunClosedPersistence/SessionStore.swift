import Foundation
import RunClosedCore

/// Atomically-persisted keep-awake session (ADR 023). Same discipline as
/// `OwnedLidAssertion` (ADR 011/015): one module owns the on-disk layout,
/// `.atomic` writes, and a missing/corrupt file loads as "no session" — never
/// as a phantom deadline that would end someone's session at boot.
///
/// JOURNAL BEFORE CHANGE. The session is written BEFORE `disablesleep` is set,
/// so a crash between the two leaves a record of intent that the next launch
/// can reconcile; if the write to the flag then fails, the caller deletes the
/// record (`clear()`). The reverse order (flag first, record second) would
/// leave an awake machine with no deadline — the failure this ADR removes.
///
/// Format on disk (`~/Library/Application Support/RunClosed/session.json`),
/// ISO-8601 dates, absent optionals omitted:
/// ```
/// {
///   "schemaVersion": 1,
///   "session": {
///     "schemaVersion": 1,
///     "id": "<uuid>",
///     "startedAt": "<ISO-8601>",
///     "endsAtWall": "<ISO-8601>",
///     "endsAtContinuous": <uint64>,
///     "bootID": "<boot session uuid>",
///     "pausedReason": "lowBattery"
///   }
/// }
/// ```
/// `load()` also reads a bare session object. An unknown `pausedReason`
/// stays paused; a truncated or unreadable file still loads as "no session".
public struct SessionStore {
    public let url: URL

    /// Canonical path: `~/Library/Application Support/RunClosed/session.json`.
    /// Creates the parent directory if needed (idempotent).
    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("session.json")
    }

    /// Test seam: explicit URL. Does NOT create the parent directory — tests
    /// own their temp tree, and a typo must not silently succeed.
    public init(url: URL) {
        self.url = url
    }

    /// The session record, or nil when there is none.
    public struct Record: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var session: KeepAwakeSession?

        public init(schemaVersion: Int = kKeepAwakeSessionSchemaVersion,
                    session: KeepAwakeSession? = nil) {
            self.schemaVersion = schemaVersion
            self.session = session
        }
    }

    /// Load the session. Missing file, unreadable file, or a file whose JSON
    /// does not decode → no session (B3: never claim an obligation we cannot
    /// prove). The file's own `schemaVersion` is surfaced so `status` can say
    /// whether the on-disk shape is from a future version.
    public func load() -> KeepAwakeSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Two accepted shapes: a bare session object (what a hand-written
        // record or a future tool — the L2 backstop — is most likely to
        // produce) and the wrapper record (`{schemaVersion, session}`). The
        // bare form is tried FIRST: the wrapper decodes to a nil session when
        // its `session` key is absent, which would mask a valid bare record.
        if let session = try? decoder.decode(KeepAwakeSession.self, from: data) {
            return session
        }
        return (try? decoder.decode(Record.self, from: data))?.session
    }

    /// The raw schemaVersion on disk, or nil when the file is absent/damaged.
    /// `status` reports it so an older/newer writer is visible rather than
    /// guessed at.
    public func storedSchemaVersion() -> Int? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let session = try? decoder.decode(KeepAwakeSession.self, from: data) {
            return session.schemaVersion
        }
        return (try? decoder.decode(Record.self, from: data))?.schemaVersion
    }

    /// Atomic write (sibling temp file + rename), ISO-8601 dates so the file
    /// stays readable by `jq` and by the CLI.
    ///
    /// Returns `false` when the record could not be encoded or written (disk
    /// full, permissions, missing directory). Journal-before-change callers
    /// must not set the flag then.
    @discardableResult
    public func save(_ session: KeepAwakeSession) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Record(session: session)) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Remove the record. Called when the session ends (expiry verified, End
    /// button, operator switch OFF) and when setting the flag failed after the
    /// record was written.
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

public let kSessionStoreSchemaVersion = kKeepAwakeSessionSchemaVersion
