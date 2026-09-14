import Foundation

/// Pure policy gate for display mutations (A04 + B3 + invariant 4).
/// UI-free so it is unit-testable without a screen — tests inject active/all
/// ID sets and assert the boolean outcomes.
public enum DisplayMutationPolicy {

    /// Decide whether a display may be DISABLED right now.
    /// Returns false if:
    ///   - the target is not in the current active set (stale: a panel
    ///     rendered before a screen was unplugged), OR
    ///   - the target IS active but disabling it would leave zero active
    ///     displays (last-active guard).
    public static func canDisable(target: UInt32, activeIDs: [UInt32]) -> Bool {
        guard activeIDs.contains(target) else { return false }   // stale target
        return activeIDs.count > 1                                // never the last one
    }

    /// Decide whether a display may be ENABLED right now. The only refusal
    /// is "target unknown" — we never enable a random display ID we have
    /// no record of. (The owned-disabled flow re-enables IDs from the
    /// persisted record; that path bypasses this check because the IDs
    /// are already vetted.)
    public static func canEnable(target: UInt32, knownIDs: [UInt32]) -> Bool {
        return knownIDs.contains(target)
    }
}
