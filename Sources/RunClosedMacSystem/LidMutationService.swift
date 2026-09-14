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

    // MARK: — Live set

    /// Set the lid stay-awake flag.
    /// - `enabled = true`  : `disablesleep 1`, claim ownership only on success.
    /// - `enabled = false` : `disablesleep 0` ONLY if we owned the flag on
    ///                       this boot (B2 — never restore what we didn't set).
    @discardableResult
    public mutating func setEnabled(_ enabled: Bool) -> Result<OperationResult, LidMutationError> {
        let prior = priorProvider()
        // B1: unknown prior blocks the mutation.
        guard LidMutationPolicy.canSet(enabled: enabled, observedPrior: prior) else {
            if prior == nil {
                return .failure(.preconditionUnknown)
            }
            return .failure(.noChangeRequested(target: enabled))
        }
        // B2: setting OFF requires ownership. The record is cross-boot
        // discarded by `OwnedLidAssertion.load()` so an old boot's leftover
        // does NOT grant us ownership on the new boot.
        if !enabled {
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
    /// this boot. Returns true when a restore was actually performed (useful
    /// for tests + CLI reporting).
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
