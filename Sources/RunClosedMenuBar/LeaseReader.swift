import Foundation
import RunClosedCore

// Minimal READ-ONLY lease reader for the G2a menu-bar app.
//
// We do NOT mutate here. The viewer just lists current leases (filtered by
// bootID in SnapshotBuilder). If the on-disk file is missing or torn we return
// an empty engine — the worst case is "no leases shown" which is honest.
//
// (The canonical LeaseStore lives in the `runclosed` CLI target. We don't
// share it cross-target in G2a — keeping it tiny and local until G2b unifies
// the persistence layer.)

enum LeaseReader {
    static func load(clock: Clock) -> LeaseEngine {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed/leases.json")
        guard let data = try? Data(contentsOf: url),
              let leases = try? JSONDecoder().decode([Lease].self, from: data) else {
            return LeaseEngine()
        }
        var engine = LeaseEngine(leases: leases)
        engine.reap(clock: clock)
        return engine
    }
}
