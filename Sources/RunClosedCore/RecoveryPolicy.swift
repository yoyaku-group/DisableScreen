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
        /// The battery guard's operator kill switch
        /// (`LowBatteryGuardSettings.isEnabled()`). The app skips the battery
        /// step when it is off and still runs the session step; the backstop is
        /// the same guard and must obey the same switch.
        public var batteryGuardEnabled: Bool

        public init(
            recordBootID: String,
            recordOwnedEnabled: Bool,
            currentBootID: String,
            session: KeepAwakeSession?,
            now: SessionPolicy.Now,
            battery: LowBatteryPolicy.Input? = nil,
            latch: LowBatteryPolicy.Latch = LowBatteryPolicy.Latch(),
            batteryGuardEnabled: Bool = true
        ) {
            self.recordBootID = recordBootID
            self.recordOwnedEnabled = recordOwnedEnabled
            self.currentBootID = currentBootID
            self.session = session
            self.now = now
            self.battery = battery
            self.latch = latch
            self.batteryGuardEnabled = batteryGuardEnabled
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
        // The operator kill switch gates the BATTERY step only, exactly as in
        // the app: deadlines are not the battery guard's to switch off.
        return Plan(
            session: session != nil,
            sessionDue: session.map { SessionPolicy.dueReason($0, now: facts.now) != nil } ?? false,
            battery: claimsFlag && facts.batteryGuardEnabled,
            ownership: ownership,
            batteryVerdict: facts.batteryGuardEnabled ? verdict : .unread)
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

    // MARK: — Proof the agent actually RUNS (ADR 024 §5)

    /// The exit code a failing backstop run reports (5 in
    /// `RecoveryBackstopService.ExitCode`). Kept here because the freshness
    /// rule needs it and Core cannot depend on MacSystem.
    public static let backendFailureExitCode: Int32 = 5

    /// The exit code of a minute that could not take the write lock (75,
    /// `EX_TEMPFAIL`). Kept here for the same reason as the failure code.
    public static let busyExitCode: Int32 = 75

    /// A registration state is not proof of execution. `SMAppService` reporting
    /// `enabled` means the agent is registered and approved; it says nothing
    /// about whether a single protective minute ever ran — an approved agent
    /// whose `BundleProgram` does not resolve still reads `enabled`.
    ///
    /// The CLI may only treat the backstop as the thing that will end a timed
    /// session when a run is PROVEN recent on the CURRENT boot. Anything the
    /// file cannot prove is "not running" — the conservative answer, and the
    /// one that keeps ADR 023's refusal intact rather than trading it for a
    /// silent unenforced deadline.
    public enum RunFreshness: Equatable, Sendable {
        /// No heartbeat file, or it does not decode.
        case never
        /// The heartbeat was written by another boot: it proves nothing about
        /// whether launchd will fire on this one.
        case otherBoot(recordBootID: String)
        /// The last run finished more than `maximumAge` ago. Deliberately
        /// conservative: a Mac that slept for hours wakes with a stale
        /// heartbeat, and launchd fires the missed interval on wake, so the
        /// next minute restores the proof. Until then, refuse.
        case stale(ageSeconds: TimeInterval)
        /// The last run exited non-zero: it started and could not do its job
        /// (5 a failed release, 3 a refusal that protected nothing). Not an
        /// enforcer, whatever its registration says.
        case lastRunFailed(exitCode: Int32)
        /// A run finished recently on this boot and did not fail.
        case fresh(ageSeconds: TimeInterval)
        /// The last run exited 75: another RunClosed writer (the app's guard
        /// tick, a CLI command) held `LidWriteLock`, so the minute did nothing
        /// and must not be read as a failure either.
        ///
        /// Kept apart from `.fresh` on purpose. It is NOT a proof — the agent
        /// never entered its locked section, so this minute establishes
        /// nothing about whether it can end a deadline — but calling it "the
        /// last run failed" told the operator the net was broken when it had
        /// simply been pre-empted, and that message cost them a `session
        /// extend` (review round 7). The direction stays fail-safe: it does
        /// not lift the ADR 023 refusal, exactly like `.lastRunFailed`, which
        /// is the rule round 5 turned into a CRITICAL.
        case lastRunBusy(ageSeconds: TimeInterval)

        /// Only a fresh, successful run makes the agent an enforcer.
        public var isEnforcing: Bool {
            if case .fresh = self { return true }
            return false
        }

        /// The precise cause, for the CLI refusal message — a generic "not
        /// running" would hide which of the four situations the operator is in.
        public var refusalHint: String {
            switch self {
            case .fresh: return ""
            case .never: return "it has never run"
            case .otherBoot: return "its last recorded run was before this restart"
            case .stale(let age):
                return "its last run was \(Int(age)) s ago (more than \(Int(RecoveryPolicy.maximumHeartbeatAge)) s)"
            case .lastRunFailed(let code): return "its last run failed (exit \(code))"
            case .lastRunBusy:
                return "its last run found another RunClosed writer holding the lock (exit 75), so it did nothing"
            }
        }
    }

    /// How old a heartbeat may be and still count as proof. Three minutes:
    /// three missed 60 s intervals, which tolerates a busy machine and one
    /// dropped launchd fire without ever being true of an agent that is not
    /// running at all.
    public static let maximumHeartbeatAge: TimeInterval = 180

    /// Grade a heartbeat. Pure, so every case is a test rather than a claim.
    ///
    /// A timestamp in the FUTURE is not fresh: it means the wall clock moved
    /// backwards, so the age is not evidence of anything.
    ///
    /// The rule: the agent ran recently on THIS boot and reported no
    /// failure.
    ///
    /// ## What this proof does and does not claim
    ///
    /// It claims exactly three things, and the CLI's message says the same:
    /// the LaunchAgent fires, `BundleProgram` resolves to a binary that runs,
    /// and that binary reaches its heartbeat write without failing. It does
    /// NOT claim a protective section executed — on a machine where nothing is
    /// ours yet, every minute is `nothingToDo`, and requiring a sealed section
    /// here made the proof unreachable by construction: the only act that
    /// would give the next minute something to do is the very
    /// `session start --for` this rule gates (circular, review round 3).
    ///
    /// The `sudo -n pmset` rail is not covered here and does not need to be:
    /// it is the same user, the same sudoers rule and the same code path
    /// `session start` itself just used to turn the flag on, one statement
    /// earlier. What is genuinely unproven is whether the agent's own
    /// subprocess environment can write the flag, and that is what the
    /// hardware qualification (PR5) measures.
    ///
    /// Only a clean exit counts. Every non-zero code means the agent started
    /// and then could not do its job: 5 a failed release, 3 a refusal (the flag
    /// is not provably ours, so nothing was protected — grading that
    /// "enforcing" would lift the ADR 023 refusal on the strength of a run that
    /// did nothing, the round-5 CRITICAL). Exit 75 gets its own name because it
    /// is not a failure but is still not a proof (see `.lastRunBusy`).
    public static func runFreshness(
        heartbeat: (at: Date, bootID: String, exitCode: Int32)?,
        currentBootID: String,
        now: Date,
        maximumAge: TimeInterval = maximumHeartbeatAge
    ) -> RunFreshness {
        guard let heartbeat else { return .never }
        guard heartbeat.bootID == currentBootID else {
            return .otherBoot(recordBootID: heartbeat.bootID)
        }
        let age = now.timeIntervalSince(heartbeat.at)
        // Checked before the age: a failed run is not made good by recency.
        guard heartbeat.exitCode == 0 else {
            // 75 is the ONE non-zero code that is not a failure: another
            // RunClosed writer held the lock, so the agent was pre-empted, not
            // broken. It is named as such (and still not a proof), so the
            // operator is not told the net is down when it merely waited. Too
            // old to be news, it is stale like any other old minute.
            if heartbeat.exitCode == busyExitCode {
                guard age >= 0, age <= maximumAge else { return .stale(ageSeconds: age) }
                return .lastRunBusy(ageSeconds: age)
            }
            return .lastRunFailed(exitCode: heartbeat.exitCode)
        }
        // A negative age means the wall clock moved backwards. That is not
        // evidence of a recent run, so it is graded stale rather than fresh.
        guard age >= 0 else { return .stale(ageSeconds: age) }
        guard age <= maximumAge else { return .stale(ageSeconds: age) }
        return .fresh(ageSeconds: age)
    }
}
