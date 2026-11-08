import Foundation
import RunClosedCore

/// Atomically-persisted latch of the thermal guard (ADR 025). Exactly the
/// discipline of `LowBatteryLatchStore`: one module owns the on-disk layout,
/// `.atomic` writes, and a missing/corrupt file reads as the default latch —
/// so a damaged file can never look like "we already released for heat" and
/// silently suppress the next episode's alert, nor like "we already alerted"
/// and swallow its first warning.
///
/// Format on disk:
/// ```
/// {
///   "schemaVersion": 1,
///   "latch": { "warnedSerious": false, "warnedCritical": false,
///              "seriousSince": null, "seriousSinceBootID": null,
///              "releasedForHeat": false },
///   "updatedAt": "<ISO-8601>"
/// }
/// ```
/// The latch deliberately survives a process restart: the app tick and the
/// ADR 024 backstop minute are two writers of the same episode, and a
/// `serious` that has already run for eight minutes must not restart its clock
/// because the menu-bar app was relaunched.
public struct ThermalLatchStore: Sendable {
    public let url: URL

    /// Canonical path: `~/Library/Application Support/RunClosed/thermal_guard.json`.
    ///
    /// Application Support, NOT `~/Library/Logs/RunClosed/`: that directory
    /// holds launchd's captured stderr (ADR 024), which is diagnostic output.
    /// This file is state the guard reads back, so it belongs with the other
    /// stores.
    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("thermal_guard.json")
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

    public struct Record: Codable, Equatable, Sendable {
        public var schemaVersion: Int = kThermalLatchSchemaVersion
        public var latch: ThermalPolicy.Latch
        public var updatedAt: String?

        public init(latch: ThermalPolicy.Latch, updatedAt: String? = nil) {
            self.latch = latch
            self.updatedAt = updatedAt
        }
    }

    public func load() -> Record {
        guard let data = try? Data(contentsOf: url),
              let rec = try? JSONDecoder().decode(Record.self, from: data) else {
            return Record(latch: ThermalPolicy.Latch())
        }
        return rec
    }

    /// Write the latch. Returns whether it actually landed.
    ///
    /// The return value is NOT optional politeness: `seriousSince` lives in
    /// this file, and the sustained-heat release reads it back on the next
    /// tick. A save that fails silently makes every tick look like the FIRST
    /// tick of an episode, so the ten-minute grace period restarts forever and
    /// the guard never releases — a protective rule that is quietly dead, with
    /// nothing in any log saying so. Same contract, and same reason, as
    /// `BackstopHeartbeatStore.save` (ADR 024): the caller must be able to tell
    /// "persisted" from "lost".
    @discardableResult
    public func save(_ record: Record) -> Bool {
        var rec = record
        rec.updatedAt = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONEncoder().encode(rec) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

public let kThermalLatchSchemaVersion = 1
