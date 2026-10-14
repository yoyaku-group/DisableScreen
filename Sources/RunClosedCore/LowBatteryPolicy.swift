import Foundation

/// Pure low-battery safety policy for the lid stay-awake flag (ADR 022).
///
/// Why it exists: `pmset disablesleep 1` (the lid stay-awake switch) also
/// blocks macOS's own emergency sleep. On 2026-10-14 the Mac ran on battery
/// with the flag ON and a heavy agent fleet, drained 41% → 1% and powered off
/// hard. With `hibernatemode 3` a sleep would have written RAM to disk and
/// preserved every process. This policy decides when RunClosed must hand the
/// machine back to the standard sleep posture.
///
/// Mirrors `LidMutationPolicy`'s stance: UI-free, I/O-free, unit-testable.
/// It never mutates anything — `LowBatteryGuardService` (MacSystem) executes
/// the decision through the ownership-gated `LidMutationService`.
///
/// Thresholds (Ben, 2026-10-15): warn at 20%, release + sleep at 10% on
/// battery, and do not re-enable the flag until back on AC with charge > 15%.
public enum LowBatteryPolicy {

    public static let warnPercent = 20
    public static let criticalPercent = 10
    /// Fast-drain trigger: time-to-empty at or below this is critical too.
    public static let criticalMinutes = 10
    /// Hysteresis: a flag the guard released is re-enabled only on AC AND
    /// strictly above this charge.
    public static let rearmPercent = 15

    // MARK: — Inputs

    /// Who owns the observed `disablesleep` flag, from RunClosed's point of
    /// view (the `OwnedLidAssertion` record vs the current boot).
    public enum LidOwnership: String, Codable, Sendable, Equatable {
        /// We set it on THIS boot — the `.automatic` path may release it (B2).
        case ownedThisBoot
        /// Our record is from a previous boot (ADR 015 `recoveryPending`):
        /// not active ownership, so the automatic path refuses to release.
        case staleRecord
        /// No ownership record — another tool or a human set the flag.
        case notOwned

        /// Pure classification of the persisted record against the boot.
        public static func classify(
            recordBootID: String,
            recordOwnedEnabled: Bool,
            currentBootID: String
        ) -> LidOwnership {
            guard recordOwnedEnabled else { return .notOwned }
            return recordBootID == currentBootID ? .ownedThisBoot : .staleRecord
        }
    }

    public struct Input: Equatable, Sendable {
        /// `true` = running on battery, `false` = on AC, `nil` = unknown.
        public var onBattery: Bool?
        public var chargePercent: Int?
        /// Minutes to empty; `nil` while macOS is still estimating.
        public var minutesRemaining: Int?
        /// Observed `disablesleep` (`pmset -g`); `nil` = unknown (B1).
        public var lidFlag: Bool?
        public var ownership: LidOwnership

        public init(onBattery: Bool?, chargePercent: Int?, minutesRemaining: Int?,
                    lidFlag: Bool?, ownership: LidOwnership) {
            self.onBattery = onBattery
            self.chargePercent = chargePercent
            self.minutesRemaining = minutesRemaining
            self.lidFlag = lidFlag
            self.ownership = ownership
        }
    }

    /// Persisted latch — prevents notification flapping and remembers that
    /// the guard (not a human) released the flag, so it can be re-armed.
    public struct Latch: Codable, Equatable, Sendable {
        public var warnedLow: Bool
        public var warnedCritical: Bool
        /// The guard released the flag and still owes the re-arm.
        public var releasedByGuard: Bool
        /// A release failed on an owned flag and the best-effort sleep was
        /// already tried this episode: later ticks keep retrying the release
        /// but do not re-run `sleepnow` / re-notify every 30 s.
        public var failedReleaseSleepTried: Bool

        public init(warnedLow: Bool = false, warnedCritical: Bool = false,
                    releasedByGuard: Bool = false, failedReleaseSleepTried: Bool = false) {
            self.warnedLow = warnedLow
            self.warnedCritical = warnedCritical
            self.releasedByGuard = releasedByGuard
            self.failedReleaseSleepTried = failedReleaseSleepTried
        }

        private enum CodingKeys: String, CodingKey {
            case warnedLow, warnedCritical, releasedByGuard, failedReleaseSleepTried
        }

        /// Tolerant decoding: a key added by a later version is optional, so
        /// an older file never decodes as "corrupt" and loses `releasedByGuard`.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            warnedLow = try c.decodeIfPresent(Bool.self, forKey: .warnedLow) ?? false
            warnedCritical = try c.decodeIfPresent(Bool.self, forKey: .warnedCritical) ?? false
            releasedByGuard = try c.decodeIfPresent(Bool.self, forKey: .releasedByGuard) ?? false
            failedReleaseSleepTried = try c.decodeIfPresent(Bool.self, forKey: .failedReleaseSleepTried) ?? false
        }

        /// Write-from-outcome (B3): set only after a readback-verified release.
        public func recordingRelease() -> Latch {
            var next = self
            next.releasedByGuard = true
            return next
        }

        /// Write-from-outcome: cleared only once the flag is observed back ON
        /// (verified re-arm, or a human re-enabled it).
        public func recordingRearm() -> Latch {
            var next = self
            next.releasedByGuard = false
            return next
        }
    }

    // MARK: — Outputs

    public enum Level: String, Codable, Sendable, Equatable {
        case unknown, ac, ok, low, critical
    }

    public enum Action: String, Codable, Sendable, Equatable {
        case none
        /// Notify the operator (no mutation).
        case warn
        /// Release `disablesleep` (ownership-gated) then `pmset sleepnow`.
        case releaseAndSleep
        /// Re-enable the flag the guard released (hysteresis satisfied).
        case rearm
    }

    public enum Reason: String, Codable, Sendable, Equatable {
        case powerSourceUnknown
        case onAC
        case rearmHeldBelowThreshold
        case rearmAfterRecovery
        case rearmObservedOn
        case chargeOK
        case lidFlagOff
        case lidFlagUnknown
        case lowBattery
        /// Low, flag ON (or unreadable) but NOT owned on this boot: the
        /// guard will not release it at 10% — the warning must say so.
        case lowBatteryUnprotected
        case criticalOwned
        case criticalStaleOwnership
        case criticalNotOwned
        case alreadyWarned
    }

    public struct Decision: Equatable, Sendable {
        public var action: Action
        public var reason: Reason
        public var level: Level
        public init(action: Action, reason: Reason, level: Level) {
            self.action = action
            self.reason = reason
            self.level = level
        }
    }

    // MARK: — Policy

    /// Classify the power situation. Never `critical`/`low` on AC or on an
    /// unknown source: the guard only ever acts on a known battery reading.
    ///
    /// The time-to-empty trigger only counts inside the warn band (≤ 20%):
    /// right after unplugging, macOS can briefly report a few minutes at a
    /// high charge, and sleeping a Mac at 80% on a noisy estimate would be a
    /// false positive. Inside the band, a fast drain (heavy agent fleet:
    /// ~1.2%/min measured on 2026-10-14) still trips before 10%.
    public static func level(_ input: Input) -> Level {
        guard let onBattery = input.onBattery else { return .unknown }
        guard onBattery else { return .ac }
        guard let pct = input.chargePercent else { return .unknown }
        if pct <= criticalPercent { return .critical }
        if pct <= warnPercent {
            if let m = input.minutesRemaining, m <= criticalMinutes { return .critical }
            return .low
        }
        return .ok
    }

    /// One evaluation tick. Returns the action to perform now and the latch
    /// to persist. `releasedByGuard` is only SET by the service from a
    /// verified outcome (`Latch.recordingRelease()`); the policy clears it
    /// only on observation (flag seen ON — ADR 009).
    public static func step(_ input: Input, latch: Latch) -> (decision: Decision, latch: Latch) {
        let lvl = level(input)
        var next = latch

        // Observation-based clear: the flag the guard released is ON again
        // (a human re-enabled it, or a previous re-arm took effect).
        if latch.releasedByGuard, input.lidFlag == true {
            next = next.recordingRearm()
        }

        switch lvl {
        case .unknown:
            return (Decision(action: .none, reason: .powerSourceUnknown, level: lvl), next)

        case .ac:
            // Re-arm warnings only once the charge is back above the warn
            // band — a weak charger flapping on/off must not re-notify.
            if let pct = input.chargePercent, pct > warnPercent {
                next.warnedLow = false
                next.warnedCritical = false
                next.failedReleaseSleepTried = false
            }
            if latch.releasedByGuard, !next.releasedByGuard {
                return (Decision(action: .none, reason: .rearmObservedOn, level: lvl), next)
            }
            if next.releasedByGuard {
                guard let pct = input.chargePercent, pct > rearmPercent else {
                    return (Decision(action: .none, reason: .rearmHeldBelowThreshold, level: lvl), next)
                }
                return (Decision(action: .rearm, reason: .rearmAfterRecovery, level: lvl), next)
            }
            // AC never acts on the flag (the "plugged but draining" case is
            // Guardian's `ac-draining` probe, not this guard).
            return (Decision(action: .none, reason: .onAC, level: lvl), next)

        case .ok:
            return (Decision(action: .none, reason: .chargeOK, level: lvl), next)

        case .low:
            // Flag OFF → macOS handles its own low-battery sleep; nothing
            // for RunClosed to protect against.
            if input.lidFlag == false {
                return (Decision(action: .none, reason: .lidFlagOff, level: lvl), next)
            }
            if next.warnedLow {
                return (Decision(action: .none, reason: .alreadyWarned, level: lvl), next)
            }
            next.warnedLow = true
            let protected = input.lidFlag == true && input.ownership == .ownedThisBoot
            return (Decision(action: .warn, reason: protected ? .lowBattery : .lowBatteryUnprotected,
                             level: lvl), next)

        case .critical:
            guard let flag = input.lidFlag else {
                // B1: cannot release a flag we cannot observe — shout instead.
                return warnCriticalOnce(reason: .lidFlagUnknown, level: lvl, latch: next)
            }
            if !flag {
                // Already released (by us or anyone): standard posture, the
                // Mac can sleep/hibernate by itself. No repeated sleepnow.
                return (Decision(action: .none, reason: .lidFlagOff, level: lvl), next)
            }
            switch input.ownership {
            case .ownedThisBoot:
                return (Decision(action: .releaseAndSleep, reason: .criticalOwned, level: lvl), next)
            case .staleRecord:
                // ADR 015/021: a record from another boot is not ownership;
                // the automatic path never turns the flag off (B2).
                return warnCriticalOnce(reason: .criticalStaleOwnership, level: lvl, latch: next)
            case .notOwned:
                return warnCriticalOnce(reason: .criticalNotOwned, level: lvl, latch: next)
            }
        }
    }

    private static func warnCriticalOnce(
        reason: Reason, level: Level, latch: Latch
    ) -> (decision: Decision, latch: Latch) {
        var next = latch
        if next.warnedCritical {
            return (Decision(action: .none, reason: .alreadyWarned, level: level), next)
        }
        next.warnedCritical = true
        return (Decision(action: .warn, reason: reason, level: level), next)
    }
}
