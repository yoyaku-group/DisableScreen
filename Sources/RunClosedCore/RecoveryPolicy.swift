import Foundation

/// Pure policy for the out-of-app recovery backstop (ADR 024).
///
/// The backstop is a per-user LaunchAgent that runs
/// `runclosed-cli recover --backstop` every 60 s. It exists for one situation:
/// the menu-bar app crashed or was quit while `pmset disablesleep 1` is ours,
/// so nothing turns the flag off and the Mac stays awake with the lid closed
/// until the battery dies (2026-10-14, the incident behind ADR 022).
///
/// Two questions, both answered here rather than in the caller:
///
///   1. Does the backstop have anything to do AT ALL? (`plan` — file facts
///      only, so the 60 s minute that finds nothing costs no `pmset` call and
///      no lock.)
///   2. Which protective steps may it run? Ending a due session and releasing
///      the flag at critical battery. It NEVER turns the flag on, NEVER
///      performs the ADR 022 re-arm, and NEVER releases a flag it cannot prove
///      is RunClosed's own.
///
/// Nothing here mutates. The release itself goes through the same services the
/// app uses (`SessionService`, `LowBatteryGuardService`), so there is one rule
/// and not two.
public enum RecoveryPolicy {

    /// What the records on disk claim — the facts the fast path may read.
    ///
    /// No `pmset`, no lock: a minute that finds nothing to protect must cost
    /// nothing.
    public struct Facts: Equatable, Sendable {
        /// `owned_lid.json` as persisted, verbatim (`OwnedLidAssertion.load`).
        public var recordBootID: String
        public var recordOwnedEnabled: Bool
        public var currentBootID: String
        /// `session.json` as persisted, if any.
        public var session: KeepAwakeSession?
        public var now: SessionPolicy.Now
        /// Battery + latch reading, when one was taken. `nil` on the file-only
        /// fast path: the plan then defers the battery step to the lock, where
        /// `LowBatteryGuardService` re-reads and re-decides from live values.
        public var battery: LowBatteryPolicy.Input?
        public var latch: LowBatteryPolicy.Latch

        public init(
            recordBootID: String,
            recordOwnedEnabled: Bool,
            currentBootID: String,
            session: KeepAwakeSession?,
            now: SessionPolicy.Now,
            battery: LowBatteryPolicy.Input? = nil,
            latch: LowBatteryPolicy.Latch = LowBatteryPolicy.Latch()
        ) {
            self.recordBootID = recordBootID
            self.recordOwnedEnabled = recordOwnedEnabled
            self.currentBootID = currentBootID
            self.session = session
            self.now = now
            self.battery = battery
            self.latch = latch
        }
    }

    /// What `LowBatteryPolicy` said, expressed in the only three shapes the
    /// backstop may take. There is deliberately no "enable" case: the ADR 022
    /// re-arm is the app's, and a decision that asks for it is withheld here
    /// rather than executed.
    public enum BatteryVerdict: Equatable, Sendable {
        /// No reading was supplied (file-only fast path).
        case unread
        /// Nothing the backstop may do: not critical, flag off or unknown, or
        /// the flag is not ours (B2 — alert only, never mutated).
        case noRelease(LowBatteryPolicy.Reason)
        /// Critical, flag observed ON and provably ours: release + sleep.
        case release(LowBatteryPolicy.Reason)
        /// The policy would turn the flag back on. A protective-only caller
        /// never does that, and leaves the debt for the app.
        case rearmWithheld(LowBatteryPolicy.Reason)

        public var reason: LowBatteryPolicy.Reason? {
            switch self {
            case .unread: return nil
            case .noRelease(let r), .release(let r), .rearmWithheld(let r): return r
            }
        }

        public var releasesFlag: Bool {
            if case .release = self { return true }
            return false
        }
    }

    /// Whether taking the write lock is worth it, and which steps it may run.
    public struct Plan: Equatable, Sendable {
        /// A session record exists (due or not): the session step runs.
        public var session: Bool
        /// The deadline of that session has passed.
        public var sessionDue: Bool
        /// Our ownership record still claims the flag (any boot): the battery
        /// step runs, because the critical-battery release is the only thing
        /// protecting an indefinite session or the plain switch once the app
        /// is gone.
        public var battery: Bool
        public var ownership: LowBatteryPolicy.LidOwnership
        public var batteryVerdict: BatteryVerdict

        /// `false` = exit 0 without a `pmset` call and without the lock.
        public var needsWork: Bool { session || battery }
    }

    /// Decide whether the backstop has anything to do, and which steps it may
    /// run. Pure: same facts in, same plan out.
    public static func plan(_ facts: Facts) -> Plan {
        let ownership = LowBatteryPolicy.LidOwnership.classify(
            recordBootID: facts.recordBootID,
            recordOwnedEnabled: facts.recordOwnedEnabled,
            currentBootID: facts.currentBootID)
        // "Claims the flag" is the RECORD's own claim, on any boot. Not
        // `ownership == .notOwned`: a record from a previous boot is exactly
        // the case ADR 022's emergency release exists for, and the session
        // record is not a substitute — `lid-stay-awake on`, the battery re-arm
        // and records from earlier releases all leave the flag ours with no
        // session on disk.
        let claimsFlag = facts.recordOwnedEnabled
        let session = facts.session
        let verdict: BatteryVerdict = facts.battery.map {
            batteryVerdict(input: $0, latch: facts.latch)
        } ?? .unread
        return Plan(
            session: session != nil,
            sessionDue: session.map { SessionPolicy.dueReason($0, now: facts.now) != nil } ?? false,
            battery: claimsFlag,
            ownership: ownership,
            batteryVerdict: verdict)
    }

    /// The battery step's decision, mapped onto what a protective-only caller
    /// may do. Reuses `LowBatteryPolicy.step` — the app's rule, not a copy.
    public static func batteryVerdict(
        input: LowBatteryPolicy.Input,
        latch: LowBatteryPolicy.Latch
    ) -> BatteryVerdict {
        let (decision, _) = LowBatteryPolicy.step(input, latch: latch)
        switch decision.action {
        case .releaseAndSleep:
            return .release(decision.reason)
        case .rearm:
            return .rearmWithheld(decision.reason)
        case .none, .warn:
            return .noRelease(decision.reason)
        }
    }
}
