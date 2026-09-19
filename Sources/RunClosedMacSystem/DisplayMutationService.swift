import Foundation
import RunClosedCore
import RunClosedPersistence

/// Orchestrates the G2b display-mutation pipeline:
///
///   live toggle  : policy(enable|disable) → mutator.setEnabled → persist owned-ids
///   launch recovery : read owned-ids → for each: mutator.setEnabled(true) →
///                     rewrite owned-ids from the REACTIVATION OUTCOME (B3:
///
///                     never rebuild from the empty live map).
///
/// Mirrors the Python main.py logic (A04 / B3 / invariant 4) without
/// touching AppKit so the service is unit-testable with a fake `DisplayMutator`.
public struct DisplayMutationService {

    public let bootID: String
    public var mutator: any DisplayMutator
    public let store: OwnedDisabledDisplays
    /// Live source of "which displays are currently active". Injected so tests
    /// can pin the topology; production passes `DisplayInventory.activeIDs`.
    public let activeIDsProvider: @Sendable () -> [UInt32]

    public init(
        bootID: String,
        mutator: any DisplayMutator,
        store: OwnedDisabledDisplays,
        activeIDsProvider: @escaping @Sendable () -> [UInt32]
    ) {
        self.bootID = bootID
        self.mutator = mutator
        self.store = store
        self.activeIDsProvider = activeIDsProvider
    }

    // MARK: — Live disable / enable

    public enum MutationError: Error, Equatable {
        case staleTarget(id: UInt32)
        case lastActiveDisplay(id: UInt32)
        case unknownTarget(id: UInt32)
        case backendFailed(message: String)
    }

    /// Disable a display NOW. Recomputes the topology at the moment of the
    /// effect (A04 invariant — never trust a stale panel-rendered active set).
    /// On success, the display is added to the owned-disabled record so a later
    /// launch can re-enable it.
    @discardableResult
    public mutating func disable(target: UInt32) -> Result<OperationResult, MutationError> {
        let active = activeIDsProvider()
        guard DisplayMutationPolicy.canDisable(target: target, activeIDs: active) else {
            if !active.contains(target) {
                return .failure(.staleTarget(id: target))
            }
            return .failure(.lastActiveDisplay(id: target))
        }
        let result = mutator.setEnabled(target, false)
        if result.state == .verified {
            // Persist ownership so the launch recovery path can try to re-enable
            // it on the next process start (mirrors main.py:_persist_owned_disabled).
            var rec = store.load()
            rec.bootID = bootID
            rec.ids = rec.ids.filter { $0 != target }
            rec.ids.append(target)
            store.save(rec)
        }
        if result.state == .failed {
            return .failure(.backendFailed(message: result.error ?? "unknown"))
        }
        return .success(result)
    }

    /// Re-enable a display we own. Used by the menu-bar "↳ Activer/Désactiver"
    /// affordance (which is currently disabled — G2a) and by the live CLI
    /// `enable <id>` subcommand.
    @discardableResult
    public mutating func enable(target: UInt32) -> Result<OperationResult, MutationError> {
        let knownIDs = activeIDsProvider()
        // For the owned-disabled re-enable path the ID may not be currently
        // active (that's the whole point — it was disabled). Accept it if it's
        // in the owned-disabled record OR in the live set.
        var rec = store.load()
        if !DisplayMutationPolicy.canEnable(target: target, knownIDs: knownIDs),
           !rec.ids.contains(target) {
            return .failure(.unknownTarget(id: target))
        }
        let result = mutator.setEnabled(target, true)
        if result.state == .verified {
            rec.bootID = bootID
            rec.ids.removeAll { $0 == target }
            store.save(rec)
        }
        if result.state == .failed {
            return .failure(.backendFailed(message: result.error ?? "unknown"))
        }
        return .success(result)
    }

    // MARK: — Launch recovery (B3)

    /// Re-enable every owned display, persist the OUTCOME (B3 — never rebuild
    /// from the empty live map). Returns the list of IDs we could NOT verifiably
    /// bring back online — those will be retried on the next launch.
    @discardableResult
    public mutating func restoreOwned() -> [UInt32] {
        var rec = store.load()
        let owned = rec.ids
        guard !owned.isEmpty else { return [] }
        var stillOwned: [UInt32] = []
        for did in owned {
            let initial: OperationResult = mutator.setEnabled(did, true)
            var r = initial
            // Post-write readback: even if the API returned 0, we want to
            // confirm the display is back in the active list. The mutator's
            // own readback covers this — if it says .verified we trust it;
            // anything else (failed / unknown) keeps the id owned.
            if r.state == .verified {
                // confirm against our own topology view too (belt + braces)
                let activeNow = activeIDsProvider()
                if !activeNow.contains(did) {
                    r = OperationResult(
                        requestID: r.requestID,
                        action: r.action,
                        state: .failed,
                        nativeRC: r.nativeRC,
                        readbackOK: false,
                        error: "post-write: display \(did) still missing from activeIDs"
                    )
                }
            }
            if r.state != .verified {
                stillOwned.append(did)
            }
        }
        rec.bootID = bootID
        rec.ids = stillOwned
        store.save(rec)
        return stillOwned
    }
}
