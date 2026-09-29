import Foundation
import RunClosedCore
import RunClosedPersistence

/// Orchestrates the G2c lid-stay-awake pipeline:
///
///   live toggle : readback(currentPrior) → policy(canSet) → pmset(disablesleep)
///                 → persisted ownership record (B2: claim ownership ONLY when
///                 readback confirms our write took effect)
///   restore     : read ownership record → if we owned it AND observable prior
///                 is still what we left, flip back → update record (B3:
///                 written from outcome)
///
/// Mirrors `DisplayMutationService` without touching AppKit so it is
/// unit-testable with a fake `LidAssertion`.
public struct LidMutationService {

    public let bootID: String
    public var mutator: any LidAssertion
    public let store: OwnedLidAssertion
    /// Live observable prior (`pmset -g` readback). Injected so tests can pin
    /// it; production passes `PowerReadback.lidStayAwake`.
    public let priorProvider: @Sendable () -> Bool?

    public init(
        bootID: String,
        mutator: any LidAssertion,
        store: OwnedLidAssertion,
        priorProvider: @escaping @Sendable () -> Bool?
    ) {
        self.bootID = bootID
        self.mutator = mutator
        self.store = store
        self.priorProvider = priorProvider
    }

    // MARK: — Cross-boot reconciliation (ADR 015)

    /// Outcome of reconciling a stale (other-boot) ownership record against
    /// the CURRENT observation.
    public enum CrossBootOutcome: Equatable, Sendable {
        /// No stale record (empty, or already ours on this boot).
        case currentBoot
        /// Stale record + observed OFF → the effect is gone; stale ownership
        /// purged AFTER the observation. Safe resting state.
        case clearedAfterObservedOff
        /// Stale record + observed ON or UNKNOWN → kept as a recovery-pending
        /// marker. NO auto-mutation (the privileged path is not qualified;
        /// `disablesleep` reboot behavior is UNDOCUMENTED — Phase 4 measures
        /// it, but the model must be fail-closed regardless of the result).
        case recoveryPending(observed: Bool?)
    }

    /// BOOT CHANGE ≠ PROOF OF RESTORATION (ADR 015). Reconcile any record left
    /// by a previous boot against the live `pmset -g` observation:
    ///   - observed OFF   → the flag is back to its safe state; the stale
    ///                      ownership may be purged (this is the ONLY path
    ///                      that clears it, and only after observation).
    ///   - observed ON    → the effect may still be ours — keep the record as
    ///                      `recoveryPending`; surface it; do NOT auto-restore.
    ///   - observed UNK.  → UNKNOWN ≠ OFF — keep `recoveryPending` (B1).
    /// A boot change alone NEVER clears state.
    @discardableResult
    public mutating func reconcileCrossBoot() -> CrossBootOutcome {
        let rec = store.load()
        guard rec.ownedEnabled, rec.bootID != bootID else {
            return .currentBoot
        }
        guard let observed = priorProvider() else {
            return .recoveryPending(observed: nil)
        }
        if observed {
            return .recoveryPending(observed: true)
        }
        // Observed OFF: the effect is verifiably gone → purge is legitimate.
        store.purge()
        return .clearedAfterObservedOff
    }

    /// Whether a previous boot left an unresolved ownership record that the
    /// current boot has not yet reconciled. Surfaces in `status` JSON as
    /// `recoveryPending: true` — an honest "we may owe a restoration" signal.
    public func hasStaleRecoveryPending() -> Bool {
        let rec = store.load()
        return rec.ownedEnabled && rec.bootID != bootID
    }

    // MARK: — Live set

    /// Who asked for the mutation (ADR 021).
    public enum Initiator: Equatable, Sendable {
        /// The app/CLI acting on its own behalf (restore-on-quit, scripts,
        /// agents). B2 applies: never turn OFF what we did not set.
        case automatic
        /// A human explicitly flipped the switch (popup toggle, CLI
        /// `--operator`). The operator IS the authority over this global
        /// flag, so ownership is not required — only B1 still binds.
        case operatorCommand
    }

    /// Set the lid stay-awake flag.
    /// - `enabled = true`  : `disablesleep 1`, claim ownership only on success.
    /// - `enabled = false` : `disablesleep 0` — for `.automatic` ONLY if we
    ///                       owned the flag on this boot (B2 — never restore
    ///                       what we didn't set). `.operatorCommand` skips the
    ///                       ownership gate: a stale cross-boot record or a
    ///                       flag set by another tool must never leave the
    ///                       switch stuck ON (ADR 021).
    @discardableResult
    public mutating func setEnabled(
        _ enabled: Bool,
        initiator: Initiator = .automatic
    ) -> Result<OperationResult, LidMutationError> {
        // Reconcile any stale cross-boot record first — a mutation attempt is
        // a natural observation point (ADR 015). No-op on the current boot.
        _ = reconcileCrossBoot()
        let prior = priorProvider()
        // B1: unknown prior blocks the mutation.
        guard LidMutationPolicy.canSet(enabled: enabled, observedPrior: prior) else {
            if prior == nil {
                return .failure(.preconditionUnknown)
            }
            return .failure(.noChangeRequested(target: enabled))
        }
        // B2: an AUTOMATIC OFF requires ownership ON THIS BOOT. A stale record
        // from another boot does NOT grant ownership (it is recovery-pending,
        // not active ownership — reconcileCrossBoot either cleared it after an
        // OFF observation or kept it pending; either way not ours to flip).
        // An operator command resolves recovery-pending by itself: the
        // verified write below replaces the stale record (ADR 021).
        if !enabled && initiator == .automatic {
            let rec = store.load()
            let weOwn = rec.bootID == bootID && rec.ownedEnabled
            if !weOwn {
                return .failure(.notOwned)
            }
        }
        // Apply.
        let result = mutator.setEnabled(enabled)
        if result.state == .verified {
            var rec = store.load()
            rec.bootID = bootID
            rec.ownedEnabled = enabled
            rec.referenceState = enabled ? "on" : "off"
            store.save(rec)
        }
        if result.state == .failed {
            return .failure(.backendFailed(message: result.error ?? "unknown"))
        }
        return .success(result)
    }

    // MARK: — Launch recovery (B3)

    /// Restore the lid-stay-awake flag to its prior state IF we owned it on
    /// THIS boot. A stale record from another boot does NOT trigger an
    /// automatic restore — the privileged path is not qualified and the
    /// reboot behavior of `disablesleep` is UNDOCUMENTED (ADR 015); the stale
    /// record is surfaced as `recoveryPending` for the operator/A14 instead.
    @discardableResult
    public mutating func restoreIfOwned() -> Bool {
        let rec = store.load()
        guard rec.bootID == bootID, rec.ownedEnabled else { return false }
        // B3 write-from-outcome: if the pmset call fails, keep the record so a
        // later attempt can retry. Don't rebuild from an unverified read.
        let _ = setEnabled(false)
        // setEnabled(false) will release ownership on success (it overwrites
        // rec.ownedEnabled = false in its verified branch).
        return true
    }
}
