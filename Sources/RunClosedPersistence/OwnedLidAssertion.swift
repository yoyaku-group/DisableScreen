import Foundation

/// Atomically-persisted record of "we own the `pmset disablesleep` flag" on
/// the current boot. Mirrors `OwnedDisabledDisplays` — the cross-target SSOT
/// pattern from ADR 011 — so the CLI writer (runclosed) is the only module
/// that owns this on-disk layout.
///
/// Format on disk (JSON, schemaVersion-tagged):
/// ```
/// {
///   "schemaVersion":  1,
///   "bootID":         "<sysctl kern.bootsession.uuid>",
///   "ownedEnabled":   true|false,
///   "referenceState": "on"|"off"
/// }
/// ```
///
/// Cross-boot discard on load: a record whose `bootID` does not match
/// `currentBootID` is treated as "we no longer know our ownership" and the
/// record is reset to empty. The machine may have rebooted and another actor
/// (the OS, the user in System Settings) may have flipped the flag in the
/// meantime — we MUST NOT restore based on a previous boot's leftover record
/// (same B3 discipline as `OwnedDisabledDisplays`).
public struct OwnedLidAssertion {
    public let url: URL
    public let currentBootID: String

    /// Canonical path: `~/Library/Application Support/RunClosed/owned_lid.json`.
    /// Creates the parent directory if needed (idempotent).
    public init(currentBootID: String) {
        self.currentBootID = currentBootID
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("owned_lid.json")
    }

    /// Inject an explicit URL — used by tests to point at a temp file rather
    /// than the user's real Application Support.
    public init(currentBootID: String, url: URL) {
        self.currentBootID = currentBootID
        self.url = url
    }

    /// The persisted record.
    public struct Record: Codable, Sendable, Equatable {
        public var schemaVersion: Int = kOwnedLidSchemaVersion
        public var bootID: String
        /// Whether we currently own the disable-sleep flag (we set it on).
        public var ownedEnabled: Bool
        /// The observable reference state at the moment we set it (B2: even if
        /// the flag was already on before, our ownership means we expect the
        /// system to behave as if it is on and we have a pending restoration
        /// obligation).
        public var referenceState: String
        public init(bootID: String, ownedEnabled: Bool, referenceState: String) {
            self.bootID = bootID
            self.ownedEnabled = ownedEnabled
            self.referenceState = referenceState
        }

        /// Empty/initial record used when we have no observation, no
        /// ownership, nothing.
        public static func empty(bootID: String) -> Record {
            return Record(bootID: bootID, ownedEnabled: false, referenceState: "off")
        }
    }

    /// Load the owned-lid record. Stale boot → empty record (we never restore
    /// based on a previous boot's evidence — same cross-boot discard as
    /// `OwnedDisabledDisplays`). Missing/corrupt file → empty record.
    /// Empty record values: `ownedEnabled = false`, `referenceState = "off"`.
    public func load() -> Record {
        guard let data = try? Data(contentsOf: url) else {
            return Record.empty(bootID: currentBootID)
        }
        guard let rec = try? JSONDecoder().decode(Record.self, from: data) else {
            return Record.empty(bootID: currentBootID)
        }
        if rec.bootID != currentBootID {
            // Previous boot owned the flag — we no longer know the actual state
            // and the user / OS may have flipped the flag in the meantime.
            // Discard.
            return Record.empty(bootID: currentBootID)
        }
        return rec
    }

    /// Atomic write of the record. `.atomic` writes a sibling temp file then
    /// renames it into place — same discipline as `OwnedDisabledDisplays`.
    public func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public let kOwnedLidSchemaVersion = 1
