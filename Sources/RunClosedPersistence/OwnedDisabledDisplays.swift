import Foundation

/// Atomically-persisted set of display IDs we OWN as disabled (A04 / B3
/// generalized). On launch we attempt to re-enable each one; FAILED or
/// exception-thrown IDs are **retained** in this record so a later run retries.
/// Successful re-enables are removed from the list.
///
/// Format on disk (JSON, schemaVersion-tagged):
/// ```
/// {
///   "schemaVersion": 1,
///   "bootID":        "...",
///   "ids":           [UInt32, ...]
/// }
/// ```
///
/// Cross-target SSOT for the on-disk format: the Swift CLI writer and the
/// (future) agent-adapter writer consume the same module. The Python app
/// uses a different file (`~/DisableScreen/settings.json`) for historical
/// reasons; that one is NOT migrated by this module.
public struct OwnedDisabledDisplays {
    public let url: URL
    public let currentBootID: String

    /// Canonical path: `~/Library/Application Support/RunClosed/owned_displays.json`.
    /// Creates the parent directory if needed (idempotent).
    public init(currentBootID: String) {
        self.currentBootID = currentBootID
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("owned_displays.json")
    }

    /// Inject an explicit URL — used by tests to point at a temp file rather
    /// than the user's real Application Support.
    public init(currentBootID: String, url: URL) {
        self.currentBootID = currentBootID
        self.url = url
    }

    /// The persisted record. BootID-tagged so we can detect stale-boot records
    /// (the displays may have been unplugged; blindly re-enabling them is
    /// unsafe — see B3 incident 2026-09-12).
    public struct Record: Codable, Sendable, Equatable {
        public var schemaVersion: Int = kOwnedSchemaVersion
        public var bootID: String
        public var ids: [UInt32]
        public init(bootID: String, ids: [UInt32]) {
            self.bootID = bootID
            self.ids = ids
        }
    }

    /// Load the owned-disabled record. Stale boot → returns an empty record
    /// (we never re-enable a previous boot's leftovers). Missing/corrupt file
    /// → empty record. This is the B3 discipline: never assume ownership.
    public func load() -> Record {
        guard let data = try? Data(contentsOf: url) else {
            return Record(bootID: currentBootID, ids: [])
        }
        guard let rec = try? JSONDecoder().decode(Record.self, from: data) else {
            return Record(bootID: currentBootID, ids: [])
        }
        if rec.bootID != currentBootID {
            // Previous boot owned these displays; we no longer know their state
            // and re-enabling them blindly could light up something that was
            // intentionally unplugged. Discard.
            return Record(bootID: currentBootID, ids: [])
        }
        return rec
    }

    /// Atomically write the record. `.atomic` writes a sibling temp file then
    /// rename(2)s it into place — a crash leaves either the old or the new
    /// file, never a torn or missing one. The previous write-tmp/remove/move
    /// dance was NOT atomic (lease file lost on crash mid-move — fixed in the
    /// PR #1 audit).
    public func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public let kOwnedSchemaVersion = 1
