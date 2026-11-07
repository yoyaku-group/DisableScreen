import Foundation
import RunClosedCore
import RunClosedPersistence

/// The out-of-app recovery backstop (ADR 024).
///
/// Runs from a per-user LaunchAgent every 60 s as `runclosed-cli recover
/// --backstop`. Its whole reason to exist: the menu-bar app enforces session
/// deadlines and the low-battery guard, so if it crashes or is quit while
/// `pmset disablesleep 1` is ours, nothing turns the flag off and the Mac stays
/// awake with the lid closed until the battery dies (2026-10-14).
///
/// Properties that are not negotiable, and are enforced here rather than
/// described:
///
/// - **Protective only.** Two steps, both of which make the Mac LESS awake:
///   end a due session, and release the flag at critical battery (followed by
///   `pmset sleepnow`). Nothing here ever enables the flag, and the ADR 022
///   re-arm is deliberately NOT performed: the guard's re-arm belongs to the
///   app, so a backstop that turned the flag on would be an unattended
///   ignition. `LowBatteryGuardService.tick()` is therefore NOT called —
///   it would re-arm.
/// - **Never blocks the app.** The lock is taken with `tryWithLock`: busy →
///   `busy` result, exit 75, launchd retries next minute. It never queues
///   behind the app or a CLI, and it never nests `LidWriteLock` (which would
///   deadlock — `withLock` opens a new fd).
/// - **App alive = `app.lock`.** If the app holds it the backstop exits at
///   once. Correctness does not depend on that probe: every step below stays
///   idempotent and readback-confirmed under `LidWriteLock`.
/// - **One rule, not two.** The decisions come from `RecoveryPolicy` (whether
///   to look at all), `SessionService.step()` (session step) and
///   `LowBatteryPolicy` via `LowBatteryGuardService.protectiveStep()` (battery
///   step) — the same code the app runs. The backstop adds no second copy of
///   the ownership gate.
/// - **No log flood.** `recovery_audit.jsonl` gets a line only when a step
///   acted or failed, never on a no-op minute.
public struct RecoveryBackstopService {

    /// Exit codes (also used as the CLI's). `busy` is 75 — `EX_TEMPFAIL`, the
    /// conventional "try again later".
    public enum ExitCode: Int32, Sendable {
        case ok = 0
        /// Refused by policy: the backstop may not do this.
        case refused = 3
        case backendFailure = 5
        case usage = 64
        /// Another writer holds `LidWriteLock`: retry on the next interval.
        case busy = 75
    }

    /// The whole point of the fast path: a minute with nothing to protect
    /// costs no `pmset` call and no lock.
    public enum Outcome: Equatable, Sendable {
        /// No ownership record claims the flag and no session is on disk.
        case nothingToDo
        /// The menu-bar app holds `app.lock`; it is in charge.
        case appAlive
        /// Another writer holds `LidWriteLock`.
        case busy
        /// The protective steps ran (possibly doing nothing, e.g. a running
        /// session that is not due yet, or a battery that is not critical).
        case completed(Report)

        public var exitCode: ExitCode {
            switch self {
            case .nothingToDo, .appAlive: return .ok
            case .busy: return .busy
            case .completed(let report): return report.exitCode
            }
        }

        /// Machine-readable name, for the CLI's JSON.
        public var rawValue: String {
            switch self {
            case .nothingToDo: return "nothingToDo"
            case .appAlive: return "appAlive"
            case .busy: return "busy"
            case .completed: return "completed"
            }
        }
    }

    /// What the protected section did. `nil` fields are steps that did not run.
    public struct Report: Equatable, Sendable {
        public var plan: RecoveryPolicy.Plan
        public var session: SessionService.StepOutcome?
        /// Battery step: the policy reason and what the guard service did.
        public var batteryReason: LowBatteryPolicy.Reason?
        public var batteryMutation: String?
        public var batteryError: String?
        public var sleepAttempted = false
        public var sleepRC: Int32?
        /// Whether anything at all was written to the audit log.
        public var audited = false

        public init(plan: RecoveryPolicy.Plan) {
            self.plan = plan
        }

        public var exitCode: ExitCode {
            if let session, session.expiry.isFailure { return .backendFailure }
            if let error = batteryError, !error.isEmpty, batteryMutation == nil {
                return .backendFailure
            }
            return .ok
        }
    }

    public var sessionService: SessionService
    public var guardService: LowBatteryGuardService
    public let lock: LidWriteLock
    public let auditLog: RecoveryAuditLog
    /// `app.lock` probe (ADR 023 `AppLivenessLock`, shared-lock probe).
    public let appIsAlive: @Sendable () -> Bool
    public var wallClock: @Sendable () -> Date

    public init(
        sessionService: SessionService,
        guardService: LowBatteryGuardService,
        lock: LidWriteLock = LidWriteLock(),
        auditLog: RecoveryAuditLog = RecoveryAuditLog(),
        appIsAlive: @escaping @Sendable () -> Bool,
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionService = sessionService
        self.guardService = guardService
        self.lock = lock
        self.auditLog = auditLog
        self.appIsAlive = appIsAlive
        self.wallClock = wallClock
    }

    /// Live wiring for `runclosed-cli recover --backstop`.
    ///
    /// One boot id, one set of stores: the session service and the guard share
    /// them, exactly as the app's tick does. The lock is the real one, so an
    /// app tick or a CLI command in flight is respected instead of raced.
    public static func live(bootID: String) -> RecoveryBackstopService {
        let session = SessionService.live(bootID: bootID)
        let guardService = LowBatteryGuardService(
            lidService: LidMutationService(
                bootID: bootID,
                mutator: LidAssertions.live(),
                store: OwnedLidAssertion(currentBootID: bootID),
                priorProvider: { PowerReadback.lidStayAwake() }),
            latchStore: LowBatteryLatchStore(),
            batteryProvider: { BatteryReadback.read() },
            sleeper: PMSetSleeper(),
            // Wired so a critical-battery release PAUSES the session instead of
            // orphaning it (ADR 023 §4), exactly as the app's tick does.
            // `protectiveStep()` never calls the session step itself — the
            // backstop runs that once, first, in the same lock section.
            sessionService: session)
        return RecoveryBackstopService(
            sessionService: session,
            guardService: guardService,
            appIsAlive: { AppLivenessLock().isHeld() })
    }

    // MARK: — The run

    /// One backstop minute.
    ///
    /// Order matters and is the fast path, cheapest first:
    ///   1. file facts only — no record claiming the flag AND no session →
    ///      exit 0 without a `pmset` call and without the lock;
    ///   2. `app.lock` held → exit 0 (the app is in charge);
    ///   3. `LidWriteLock`, NON-blocking → busy → exit 75;
    ///   4. inside that one section: session step, then battery step.
    public mutating func run() -> Outcome {
        let now = sessionService.currentNow()
        let record = sessionService.ownershipRecord()
        let session = sessionService.load()
        let facts = RecoveryPolicy.Facts(
            recordBootID: record.bootID,
            recordOwnedEnabled: record.ownedEnabled,
            currentBootID: now.bootID,
            session: session,
            now: now,
            battery: nil,
            latch: guardService.latchStore.load().latch)
        let plan = RecoveryPolicy.plan(facts)
        // 1 — nothing is ours and nothing is scheduled: no lock, no pmset.
        guard plan.needsWork else { return .nothingToDo }
        // 2 — the app is running: it owns enforcement, and the probe is free.
        guard !appIsAlive() else { return .appAlive }
        // 3 — never queue behind the app or a CLI.
        guard let report = lock.tryWithLock({ lockedRun(plan: plan, recordBootID: record.bootID) })
        else { return .busy }
        return .completed(report)
    }

    /// The ONE `LidWriteLock` section. It must not take the lock again:
    /// `SessionService.step()` and `LowBatteryGuardService.protectiveStep()`
    /// both run on the caller's section by contract.
    private mutating func lockedRun(plan: RecoveryPolicy.Plan, recordBootID: String) -> Report {
        var report = Report(plan: plan)

        // — Session step: expire a due session (`.sessionRecovery` for its own
        // previous-boot record), or reconcile an orphan. Same decisions as the
        // app's tick; no second copy.
        if plan.session {
            let step = sessionService.step()
            report.session = step
            if auditSession(step, recordBootID: recordBootID) { report.audited = true }
        }

        // — Battery step: only while our record claims the flag. The decision
        // is computed from LIVE values inside the lock (the file-only fast path
        // had no battery reading), so a stale reading never drives a release.
        //
        // It runs even when the session step failed: the two are independent
        // protections, and a failed release is exactly the moment the battery
        // rule matters most. The exit code aggregates both.
        guard plan.battery else { return report }
        let battery = guardService.protectiveStep()
        report.batteryReason = battery.decision.reason
        report.batteryMutation = battery.mutation?.rawValue
        report.batteryError = battery.mutationError
        report.sleepAttempted = battery.sleepAttempted
        report.sleepRC = battery.sleepRC
        switch battery.mutation {
        case .released, .releaseFailed, .releaseRefused:
            auditBattery(battery, recordBootID: recordBootID)
            report.audited = true
        case .rearmWithheld:
            // The app owes a re-arm and the backstop will not do it. Recording
            // it keeps "nothing happened" from being the only trace.
            audit(.init(
                ts: timestamp(),
                bootID: sessionService.continuous.bootID,
                step: "batteryRearm",
                outcome: "withheld",
                reason: battery.decision.reason.rawValue,
                detail: "a re-arm is the app's; the backstop never turns the flag on",
                chargePercent: battery.chargePercent,
                minutesRemaining: battery.minutesRemaining,
                recordBootID: recordBootID.isEmpty ? nil : recordBootID))
            report.audited = true
        case .none:
            break
        }
        return report
    }

    // MARK: — Audit

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: wallClock())
    }

    private mutating func audit(_ entry: RecoveryAuditLog.Entry) {
        auditLog.append(entry)
    }

    /// One line for the session step, and ONLY when it did something: a
    /// running session that is not due yet is a no-op minute.
    @discardableResult
    private mutating func auditSession(_ step: SessionService.StepOutcome,
                                       recordBootID: String) -> Bool {
        let boot = step.bootID.isEmpty ? sessionService.continuous.bootID : step.bootID
        switch step.expiry {
        case .noSession, .notDue:
            // A reconciliation only matters when it changed something; the
            // service returns `nil` when there was nothing to reconcile.
            guard step.expiry == .notDue, let reconciled = step.reconciled else { return false }
            audit(.init(
                ts: timestamp(),
                bootID: boot,
                step: "sessionReconcile",
                outcome: reconciled == .cleared ? "cleared" : "repaused",
                detail: "flag read off",
                recordBootID: recordBootID.isEmpty ? nil : recordBootID))
            return true
        case .ended(let end):
            audit(.init(
                ts: timestamp(),
                bootID: boot,
                step: "sessionExpiry",
                outcome: end.rawValue,
                reason: "deadlinePassed",
                detail: step.reconciled.map { "reconciled:\($0)" },
                recordBootID: recordBootID.isEmpty ? nil : recordBootID,
                error: end.failureMessage))
            return true
        case .retained(let message):
            audit(.init(
                ts: timestamp(),
                bootID: boot,
                step: "sessionExpiry",
                outcome: "retained",
                reason: "deadlinePassed",
                recordBootID: recordBootID.isEmpty ? nil : recordBootID,
                error: message))
            return true
        }
    }

    private mutating func auditBattery(_ battery: LowBatteryGuardService.ProtectiveOutcome,
                                       recordBootID: String) {
        audit(.init(
            ts: timestamp(),
            bootID: sessionService.continuous.bootID,
            step: "batteryRelease",
            outcome: battery.mutation?.rawValue ?? "none",
            reason: battery.decision.reason.rawValue,
            detail: battery.sleepAttempted ? "sleep attempted" : nil,
            chargePercent: battery.chargePercent,
            minutesRemaining: battery.minutesRemaining,
            recordBootID: recordBootID.isEmpty ? nil : recordBootID,
            error: battery.mutationError,
            sleepRC: battery.sleepRC))
    }
}
