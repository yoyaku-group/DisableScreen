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
/// Cross-boot semantics (ADR 015 — BOOT CHANGE ≠ PROOF OF RESTORATION):
/// `load()` NEVER silently discards a record because `bootID` changed. The
/// persistence layer returns the record verbatim; deciding what to do with a
/// stale record belongs to `LidMutationService.reconcileCrossBoot(observed:)`,
/// which acts on OBSERVATION (`pmset -g` readback), never on the boot change
/// alone. This differs deliberately from `OwnedDisabledDisplays` (G2b):
/// a leftover owned display is a local, visually-obvious effect, while
/// `disablesleep` is a global, invisible flag whose reboot persistence is
/// UNDOCUMENTED and must be measured (Phase 4 hardware protocol) — the model
/// must be fail-closed in BOTH observed outcomes until then.
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

        /// A record written by a previous boot that still claims ownership.
        /// The effect may or may not still be present — only a readback can
        /// tell (ADR 015).
        public var isStaleRecoveryPending: Bool {
            return ownedEnabled
        }
    }

    /// Load the owned-lid record VERBATIM. A record from another boot is
    /// returned with its original `bootID` — it is the caller's (service
    /// layer's) job to reconcile it against an observation. Missing/corrupt
    /// file → empty record (no phantom ownership, B3).
    public func load() -> Record {
        guard let data = try? Data(contentsOf: url) else {
            return Record.empty(bootID: currentBootID)
        }
        guard let rec = try? JSONDecoder().decode(Record.self, from: data) else {
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

    /// Explicitly clear the record (purge a stale ownership AFTER an
    /// observation confirmed the effect is gone — ADR 015). The persistence
    /// layer exposes this deliberately: clearing is a decision, not a
    /// side-effect of `load()`.
    public func purge() {
        save(Record.empty(bootID: currentBootID))
    }
}

public let kOwnedLidSchemaVersion = 1
