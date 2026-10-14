import Foundation
import RunClosedCore

/// Atomically-persisted latch of the low-battery guard (ADR 022). Same
/// discipline as `OwnedLidAssertion` (ADR 011): one module owns the on-disk
/// layout, `.atomic` writes, missing/corrupt file → default latch (no phantom
/// "released" state, so a corrupt file can never trigger an automatic re-arm).
///
/// Format on disk:
/// ```
/// {
///   "schemaVersion": 1,
///   "latch": { "warnedLow": false, "warnedCritical": false, "releasedByGuard": false },
///   "updatedAt": "<ISO-8601>",
///   "releasedBootID": "<boot uuid of the last verified release, if any>"
/// }
/// ```
/// The latch deliberately survives a reboot: if the Mac hibernated or died
/// after the guard released the flag, the re-arm owed to the operator must
/// still happen once the hysteresis allows it.
public struct LowBatteryLatchStore {
    public let url: URL

    /// Canonical path: `~/Library/Application Support/RunClosed/low_battery_guard.json`.
    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("low_battery_guard.json")
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

    public struct Record: Codable, Equatable, Sendable {
        public var schemaVersion: Int = kLowBatteryLatchSchemaVersion
        public var latch: LowBatteryPolicy.Latch
        public var updatedAt: String?
        public var releasedBootID: String?

        public init(latch: LowBatteryPolicy.Latch, updatedAt: String? = nil,
                    releasedBootID: String? = nil) {
            self.latch = latch
            self.updatedAt = updatedAt
            self.releasedBootID = releasedBootID
        }
    }

    public func load() -> Record {
        guard let data = try? Data(contentsOf: url),
              let rec = try? JSONDecoder().decode(Record.self, from: data) else {
            return Record(latch: LowBatteryPolicy.Latch())
        }
        return rec
    }

    public func save(_ record: Record) {
        var rec = record
        rec.updatedAt = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONEncoder().encode(rec) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public let kLowBatteryLatchSchemaVersion = 1
