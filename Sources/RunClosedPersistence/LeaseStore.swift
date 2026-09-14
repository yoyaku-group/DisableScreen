import Foundation
import RunClosedCore

/// Atomically-persisted lease set (ADR 004). Backed by a JSON file under
/// Application Support; invalidated across boots via the Core's reap().
///
/// Cross-target SSOT for the on-disk format (ADR 010 follow-up): the `runclosed`
/// CLI writes here, the `RunClosedMenuBar` viewer reads here. Both paths
/// previously duplicated this logic (10–30 lines each, drift risk on the path
/// string and on the atomic-write discipline). This module owns the contract
/// — only one place to update if the on-disk layout ever changes.
public struct LeaseStore {
    public let url: URL
    public let clock: Clock

    /// Canonical path: `~/Library/Application Support/RunClosed/leases.json`.
    /// Creates the parent directory if needed (idempotent).
    public init(clock: Clock) {
        self.clock = clock
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("leases.json")
    }

    /// Inject an explicit URL — used by tests to point at a temp file rather
    /// than the user's real Application Support. Production callers use the
    /// canonical-path init above.
    public init(clock: Clock, url: URL) {
        self.clock = clock
        self.url = url
    }

    public func load() -> LeaseEngine {
        guard let data = try? Data(contentsOf: url),
              let leases = try? JSONDecoder().decode([Lease].self, from: data) else {
            return LeaseEngine()
        }
        var engine = LeaseEngine(leases: leases)
        engine.reap(clock: clock)   // drop stale/other-boot on every load
        return engine
    }

    public func save(_ engine: LeaseEngine) {
        guard let data = try? JSONEncoder().encode(engine.leases) else { return }
        // `.atomic` writes a sibling temp file then rename(2)s it into place in a
        // single step — a crash leaves either the old file or the new one, never
        // a torn or missing one. (The previous remove-then-move dance was NOT
        // atomic: a crash between the two lost the lease file entirely.)
        try? data.write(to: url, options: .atomic)
    }
}
