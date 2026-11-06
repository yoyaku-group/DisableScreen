import AppKit
import RunClosedCore
import RunClosedApp

/// Immutable description of one popup render. Built on the main thread from
/// live reads (the reads themselves are cheap: CG inventory + dlopen'd
/// brightness + the dim-controller's in-memory map). `pmset` is the only
/// subprocess involved and it feeds `lid` from the shared 5s status cache.
struct PopupState {

    struct DisplayCard {
        var id: UInt32
        var name: String
        var builtin: Bool
        var resolution: String
        var brightness: Double?          // nil → no brightness row
        var brightnessFloor: Double      // external: 0.08 (software dim floor)
        var isDisabled: Bool
        var canToggle: Bool              // false = last active display / busy
        var modes: [DisplayModeSelection.Mode]
        var selectedModeIndex: Int?
        var ambiguous: Bool
    }

    /// The timed keep-awake session, as the popup renders it (ADR 023).
    struct SessionRow {
        /// "Until 14:30 · 2 h 41 left" while one runs; nil when there is none.
        var label: String?
        /// A timed session is running (duration buttons hidden, End/+30 shown).
        var timed: Bool
        /// An indefinite session — today's plain switch — is running.
        var indefinite: Bool
        /// Paused by the low-battery guard: the deadline survives.
        var pausedReason: String?
        /// True once the deadline passed and the tick has not caught up yet.
        var due: Bool

        var running: Bool { timed || indefinite }
        /// Duration buttons are only offered when no session is running.
        var showsDurationButtons: Bool { !running }
    }

    var displays: [DisplayCard]
    var lid: SnapshotViewModel.PowerState
    var lidCanToggle: Bool               // false while unknown / busy
    var lidPending: Bool                 // mutation in flight → switch disabled
    var lidError: String?                // last refused/failed toggle, shown under the label
    var loginItemEnabled: Bool
    var loginItemAvailable: Bool
    var leasesSummary: String?           // "2 sessions · claude, codex" or nil
    var busy: Bool                       // any mutation in flight
    var session: SessionRow              // ADR 023
}
