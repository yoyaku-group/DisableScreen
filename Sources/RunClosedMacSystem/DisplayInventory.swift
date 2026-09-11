import Foundation
import CoreGraphics
import RunClosedCore

/// Read-only display inventory via CoreGraphics (ADR: read before any mutation).
/// This layer NEVER mutates displays; it only observes. Brightness capability is
/// reported honestly: builtin = native, external = software dim (A02/A13 — no
/// proven per-monitor DDC write path on this hardware).
public enum DisplayInventory {
    public static func snapshot() -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        // Detect ambiguity: identical (builtin, name) with no distinguishing info.
        var out: [DisplaySnapshot] = []
        for id in ids {
            let builtin = CGDisplayIsBuiltin(id) != 0
            let identity = DisplayIdentity(displayID: id, isBuiltin: builtin,
                                           localizedName: name(for: id, builtin: builtin))
            let cap: DisplayCapability = builtin
                ? DisplayCapability(brightness: .supported, brightnessBackend: "native", deactivate: .experimental)
                : DisplayCapability(brightness: .supported, brightnessBackend: "softwareDim", deactivate: .supported)
            out.append(DisplaySnapshot(identity: identity, capability: cap, currentMode: mode(for: id)))
        }
        // Flag ambiguous pairs (same name + kind, e.g. two identical externals).
        var seen: [String: Int] = [:]
        for s in out { seen["\(s.identity.isBuiltin)-\(s.identity.localizedName)", default: 0] += 1 }
        for i in out.indices {
            let key = "\(out[i].identity.isBuiltin)-\(out[i].identity.localizedName)"
            if (seen[key] ?? 0) > 1 { out[i].identity.ambiguous = true }
        }
        return out
    }

    public static func activeIDs() -> [UInt32] { snapshot().map { $0.identity.displayID } }

    private static func mode(for id: CGDirectDisplayID) -> String {
        guard let m = CGDisplayCopyDisplayMode(id) else { return "-" }
        return "\(m.width)x\(m.height)"
    }

    private static func name(for id: CGDirectDisplayID, builtin: Bool) -> String {
        // CoreGraphics has no localized name; keep it dependency-free and honest.
        builtin ? "Built-in Display" : "External Display \(id)"
    }
}
