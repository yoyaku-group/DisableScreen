import Foundation

/// Pure policy gate for `pmset disablesleep` mutations (B1 + B2 + invariant 4).
/// Mirrors DisplayMutationPolicy's stance — UI-free, unit-testable without a
/// real `pmset` invocation.
///
/// Important: this policy intentionally knows nothing about persistence. The
/// "do we own the flag" decision lives in `LidMutationService` (MacSystem),
/// where both the readback and the on-disk `OwnedLidAssertion` record are
/// available. Core can only resolve abstract facts: observed prior state +
/// intended new state.
public enum LidMutationPolicy {

    /// Decide whether `disablesleep` MAY be flipped to the requested `enabled`
    /// value at this moment.
    ///
    /// Inputs:
    ///   - `enabled`        : the value we intend to set (`true` = keep awake)
    ///   - `observedPrior`  : last readback of the flag (`true`/`false`); `nil`
    ///                        means the readback could not determine the state
    ///                        (UNKNOWN ≠ OFF — ADR 009).
    ///
    /// Returns `false` (refuse) in the B1 case (`observedPrior == nil`): any
    /// mutation built on an unobservable base could silently change a global,
    /// persistent power-management posture. The B2 ownership gate is enforced
    /// separately in the service layer (which can also look at the persisted
    /// ownership record).
    ///
    /// Always-on guard: setting `enabled = true` on `observedPrior = true`
    /// is a NO-OP and is refused here so the service layer emits an explicit
    /// (not silently swallows) "already on" signal.
    public static func canSet(
        enabled: Bool,
        observedPrior: Bool?
    ) -> Bool {
        // B1: unknown prior state always blocks the mutation.
        guard let prior = observedPrior else { return false }
        // No-op refusal — emit an explicit "already in that state" rather than
        // a silent success. Caller still owns the ownership gate.
        if enabled && prior { return false }
        if !enabled && !prior { return false }
        return true
    }
}
