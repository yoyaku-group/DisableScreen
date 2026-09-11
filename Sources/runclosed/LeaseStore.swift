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
        // Atomic write: temp + rename, so a crash never leaves a torn file.
        let tmp = url.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }
}
