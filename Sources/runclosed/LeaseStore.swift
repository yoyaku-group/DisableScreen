import Foundation
import RunClosedCore

/// Atomically-persisted lease set (ADR 004). Backed by a JSON file under
/// Application Support; invalidated across boots via the Core's reap().
struct LeaseStore {
    let url: URL
    let clock: Clock

    init(clock: Clock) {
        self.clock = clock
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("leases.json")
    }

    func load() -> LeaseEngine {
        guard let data = try? Data(contentsOf: url),
              let leases = try? JSONDecoder().decode([Lease].self, from: data) else {
            return LeaseEngine()
        }
        var engine = LeaseEngine(leases: leases)
        engine.reap(clock: clock)   // drop stale/other-boot on every load
        return engine
    }

    func save(_ engine: LeaseEngine) {
        guard let data = try? JSONEncoder().encode(engine.leases) else { return }
        // `.atomic` writes a sibling temp file then rename(2)s it into place in a
        // single step — a crash leaves either the old file or the new one, never
        // a torn or missing one. (The previous remove-then-move dance was NOT
        // atomic: a crash between the two lost the lease file entirely.)
        try? data.write(to: url, options: .atomic)
    }
}
