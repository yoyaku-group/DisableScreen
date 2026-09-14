import Foundation
import RunClosedCore
#if canImport(RunClosedMacSystem)
import RunClosedMacSystem
#endif

// Pure presentation logic for the menu-bar app (ADR 002 / ADR 009).
//
// Why this lives in a no-AppKit module:
// - Tests run on Linux CI as well as on the build host (XCTest target with no
//   Cocoa dependency). AppKit-free means XCTest runs the same suite both places.
// - Logic stays out of AppDelegate so the next migration (G2b/G2c) only rewires
//   actions, never the truth-of-state.
//
// Three guarantees (all unit-tested):
// 1. `unknown` power is never rendered as "off" (ADR 009 — UNKNOWN != OFF).
// 2. `softwareDim` is never rendered as "native".
// 3. Leases from a different bootID are filtered out (LeaseEngine.reap() does
//    this on every load too — defence in depth).

public struct SnapshotViewModel: Sendable, Equatable {
    public var displays: [DisplayRow]
    public var lidStayAwake: PowerState
    public var leases: [LeaseRow]
    public var snapshotTakenAt: Date

    public enum PowerState: String, Sendable, Equatable {
        case on
        case off
        case unknown   // never collapsed into off — ADR 009 / A10
    }

    public struct DisplayRow: Sendable, Equatable {
        public var id: UInt32
        public var label: String
        public var builtin: Bool
        public var mode: String
        public var brightnessLabel: String   // human label, never lies about backend
        public var canDeactivate: Bool
        public var ambiguous: Bool
    }

    public struct LeaseRow: Sendable, Equatable {
        public var id: String
        public var owner: String
        public var state: String
        public var workSource: String
        public var deadlineEpoch: Date?
    }

    public init(displays: [DisplayRow], lidStayAwake: PowerState, leases: [LeaseRow],
                snapshotTakenAt: Date) {
        self.displays = displays
        self.lidStayAwake = lidStayAwake
        self.leases = leases
        self.snapshotTakenAt = snapshotTakenAt
    }
}

public enum SnapshotBuilder {
    /// Render a view-model from the read-only system layer.
    /// `lidStayAwake` is `Bool?` — `nil` means unreadable. We surface that as
    /// `.unknown`, never collapse it into `.off` (ADR 009 invariant).
    public static func make(
        now: Date,
        snapshots: [DisplaySnapshot],
        lidStayAwake: Bool?,
        leases: [Lease],
        currentBootID: String
    ) -> SnapshotViewModel {
        let power: SnapshotViewModel.PowerState = {
            guard let v = lidStayAwake else { return .unknown }
            return v ? .on : .off
        }()

        // Detect ambiguity ourselves too — defence in depth. DisplayInventory
        // already flags ambiguous pairs, but a future backend (or a test) might
        // pass pre-built DisplaySnapshots where the flag is stale or absent.
        let ambiguityByID: [UInt32: Bool] = {
            var counts: [String: [UInt32]] = [:]
            for s in snapshots {
                counts["\(s.identity.isBuiltin)-\(s.identity.localizedName)", default: []].append(s.identity.displayID)
            }
            var out: [UInt32: Bool] = [:]
            for s in snapshots {
                let key = "\(s.identity.isBuiltin)-\(s.identity.localizedName)"
                if (counts[key]?.count ?? 0) > 1 { out[s.identity.displayID] = true }
            }
            return out
        }()

        let rows = snapshots.map { snap -> SnapshotViewModel.DisplayRow in
            let isAmbiguous = snap.identity.ambiguous || (ambiguityByID[snap.identity.displayID] ?? false)
            let label: String
            if isAmbiguous {
                label = "\(snap.identity.localizedName) ⚠︎ (ambigü)"
            } else {
                label = snap.identity.localizedName
            }
            // Capability is honest by construction (DisplayInventory reports the
            // real backend). The UI label MUST never say "native" if the
            // backend is softwareDim.
            let brightnessLabel: String
            switch snap.capability.brightness {
            case .supported:
                brightnessLabel = "luminosité : \(snap.capability.brightnessBackend)"
            case .experimental:
                brightnessLabel = "luminosité : expérimentale (\(snap.capability.brightnessBackend))"
            case .unsupported:
                brightnessLabel = "luminosité : non supportée"
            case .unknown:
                brightnessLabel = "luminosité : état inconnu"
            }
            return SnapshotViewModel.DisplayRow(
                id: snap.identity.displayID,
                label: label,
                builtin: snap.identity.isBuiltin,
                mode: snap.currentMode,
                brightnessLabel: brightnessLabel,
                canDeactivate: snap.capability.deactivate == .supported,
                ambiguous: isAmbiguous
            )
        }

        let leases = leases
            .filter { $0.bootID == currentBootID }    // defence in depth
            .map { lease in
                SnapshotViewModel.LeaseRow(
                    id: lease.id,
                    owner: lease.owner,
                    state: lease.state.rawValue,
                    workSource: lease.workSource.rawValue,
                    deadlineEpoch: nil   // monotonic clock intentionally not exposed to UI
                )
            }

        return SnapshotViewModel(displays: rows, lidStayAwake: power, leases: leases,
                                  snapshotTakenAt: now)
    }
}

/// Plain-text rendering of the view-model — used both by the AppKit menu and by
/// `doctor`-style textual snapshots. Pure function, fully testable.
public enum SnapshotRenderer {
    public static func render(_ vm: SnapshotViewModel) -> String {
        var lines: [String] = []
        lines.append("RunClosed — \(formatted(vm.snapshotTakenAt))")

        // Lid stay-awake — render UNKNOWN with its own copy, never silently off.
        switch vm.lidStayAwake {
        case .on:
            lines.append("Capot · désactivation sommeil : activée")
        case .off:
            lines.append("Capot · désactivation sommeil : désactivée")
        case .unknown:
            lines.append("Capot · désactivation sommeil : état inconnu (pmset illisible)")
        }

        if vm.displays.isEmpty {
            lines.append("Écrans : aucun")
        } else {
            lines.append("Écrans (\(vm.displays.count)) :")
            for d in vm.displays {
                var line = "  • \(d.label) [id \(d.id), \(d.mode)]"
                line += " — \(d.brightnessLabel)"
                if d.canDeactivate {
                    line += " (désactivable)"
                }
                lines.append(line)
            }
        }

        if vm.leases.isEmpty {
            lines.append("Sessions actives : aucune")
        } else {
            lines.append("Sessions actives (\(vm.leases.count)) :")
            for l in vm.leases {
                lines.append("  • \(l.owner) — \(l.workSource) — \(l.state)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func formatted(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
