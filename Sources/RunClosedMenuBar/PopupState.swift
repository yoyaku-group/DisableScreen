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

    var displays: [DisplayCard]
    var lid: SnapshotViewModel.PowerState
    var lidCanToggle: Bool               // false while unknown / busy
    var lidPending: Bool                 // mutation in flight → switch disabled
    var loginItemEnabled: Bool
    var loginItemAvailable: Bool
    var leasesSummary: String?           // "2 sessions · claude, codex" or nil
    var busy: Bool                       // any mutation in flight
}
