import Foundation
import RunClosedCore

/// Read-only thermal readback through the public `ProcessInfo` API (ADR 025).
///
/// No subprocess, no privilege, no mutation — the same shape as
/// `BatteryReadback` / `PowerReadback`, and the only place in the product that
/// spells a Foundation thermal constant. The policy side
/// (`ThermalPolicy` / `ThermalState`) stays Foundation-free so it is testable
/// everywhere and readable without knowing which enum Apple used.
public enum ThermalReadback {

    /// Live read. `ProcessInfo.thermalState` has no "unknown" case, so this
    /// always answers with one of the four states.
    public static func read() -> ThermalState {
        map(ProcessInfo.processInfo.thermalState)
    }

    /// Pure mapping, so the four-way translation is a test rather than a claim.
    ///
    /// `@unknown default` is `.nominal`, not `.critical`: a case Apple adds
    /// later is far more likely to sit between `nominal` and `fair` than to be
    /// an unknowable emergency, and inventing a `critical` would release the
    /// operator's flag for heat that was never measured. The protective
    /// direction is preserved where it matters — a real emergency arrives as
    /// `.critical` today.
    public static func map(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

/// The ONE observer on `ProcessInfo.thermalStateDidChangeNotification`
/// (ADR 025): placed at launch, removed at quit.
///
/// The thermal state changes on the system's schedule, not on the guard's 30 s
/// timer, and a `critical` arriving ten seconds after a tick must not wait half
/// a minute. This posts a tick when it fires; it holds no state of its own and
/// makes no decision.
public final class ThermalObserver: @unchecked Sendable {
    private var token: NSObjectProtocol?

    public init() {}

    /// Install the observer. Idempotent — a second call does nothing.
    ///
    /// `onChange` runs on the posting thread, so callers hop back to their own
    /// queue themselves; this observer never touches the UI.
    public func start(_ onChange: @escaping @Sendable () -> Void) {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil) { _ in onChange() }
    }

    /// Remove it (called at quit).
    public func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    deinit { stop() }
}
