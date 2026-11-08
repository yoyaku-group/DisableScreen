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

        /// Whether a `rearmWithheld` episode is open after this minute. `nil`
        /// when the battery step did not run, so the caller carries the
        /// previous value forward instead of guessing.
        public var rearmWithheldEpisode: Bool? {
            if case .completed(let report) = self { return report.rearmWithheldEpisode }
            return nil
        }

        /// What the battery step did, when it ran at all.
        public var batteryMutation: LowBatteryGuardService.ProtectiveMutation? {
            if case .completed(let report) = self { return report.batteryMutation }
            return nil
        }

        /// The repeating-failure key already audited, when this outcome carried
        /// one. `nil` means "leave the heartbeat's value alone".
        public var auditedFailureKey: String? {
            if case .completed(let report) = self { return report.auditedFailureKey }
            return nil
        }

        /// Whether this minute actually reached the battery step. It is what
        /// makes `auditedFailureKey` readable as a tri-state: without it, a run
        /// whose battery step RAN and found nothing to report carries `nil`
        /// exactly like a run that never got there, and the heartbeat could not
        /// tell "the failure episode ended, forget the key" from "this minute
        /// proved nothing, keep it" (review round 10).
        public var batteryStepRan: Bool {
            if case .completed(let report) = self { return report.batteryStepRan }
            return false
        }

        /// The repeating SESSION-expiry failure key, same tri-state contract as
        /// `auditedFailureKey` and gated by `sessionStepRan` (review round 15).
        public var auditedSessionFailureKey: String? {
            if case .completed(let report) = self { return report.auditedSessionFailureKey }
            return nil
        }

        /// Whether the session step ran. A run with no session to expire never
        /// touches the session key, so it must carry it forward.
        public var sessionStepRan: Bool {
            if case .completed(let report) = self { return report.sessionStepRan }
            return false
        }
    }

    /// What the protected section did. `nil` fields are steps that did not run.
    public struct Report: Equatable, Sendable {
        public var plan: RecoveryPolicy.Plan
        public var session: SessionService.StepOutcome?
        /// Battery step: the policy reason and what the guard service did.
        public var batteryReason: LowBatteryPolicy.Reason?
        /// Typed, not a `String`: comparing `rawValue` literals from another
        /// file let a renamed case silently turn a FAILED critical release into
        /// `.ok`, with no compile error.
        public var batteryMutation: LowBatteryGuardService.ProtectiveMutation?
        public var batteryError: String?
        public var sleepAttempted = false
        public var sleepRC: Int32?
        /// Whether anything at all was written to the audit log.
        public var audited = false
        /// Whether a `rearmWithheld` episode is currently OPEN, i.e. this run
        /// saw the condition and it has now been reported. Carried into the
        /// heartbeat so the next minute does not report it again.
        public var rearmWithheldEpisode = false
        /// The identifier of a repeating failure this run audited, carried into
        /// the heartbeat so the next minute with the SAME failure stays quiet.
        public var auditedFailureKey: String?
        /// Whether the battery step ran at all. `false` means this minute
        /// proves nothing about the failure episode, so the heartbeat must
        /// carry its key forward (see `Outcome.batteryStepRan`).
        public var batteryStepRan = false
        /// The identifier of a repeating SESSION-expiry failure this run
        /// audited, plus whether the session step ran at all — the same
        /// once-per-episode discipline the battery step uses. `.retained` keeps
        /// the record so the next minute retries, which is correct, but it also
        /// repeats the same audit line 1 440 times a day (review round 15).
        public var auditedSessionFailureKey: String?
        public var sessionStepRan = false
        /// Thermal step (ADR 025): the policy reason when it governed this run.
        public var thermalReason: ThermalPolicy.Reason?
        public var thermalMutation: ThermalGuardService.MutationOutcome?
        public var thermalError: String?
        /// A heat release ended the session — the deadline is gone, not paused.
        public var sessionEndedByHeat = false
        /// Whether the thermal step ran at all (the kill switch can stop it).
        public var thermalStepRan = false
        /// The thermal latch could not be persisted: the sustained-heat clock
        /// restarts every minute, so the ten-minute release cannot fire. A
        /// protective action that cannot happen is a failure, not a detail.
        public var thermalLatchSaveFailed = false

        public init(plan: RecoveryPolicy.Plan) {
            self.plan = plan
        }

        public var exitCode: ExitCode {
            // A failed session release wins: the record stayed on disk and the
            // deadline is NOT enforced, which is the most serious outcome a
            // backstop minute can produce.
            if let session, session.expiry.isFailure { return .backendFailure }
            // ADR 025: the thermal step maps its own outcome, on the same rule
            // as the battery step — a protective action that did not happen is
            // never announced as a healthy minute.
            switch thermalMutation {
            case .releaseFailed: return .backendFailure
            case .releaseRefused: return .refused
            case .released, nil: break
            }
            // A latch that cannot be written makes the sustained-heat release
            // unreachable, so this minute did NOT establish that heat is
            // covered. Reporting it as ok would feed a "fresh" heartbeat to the
            // CLI on the strength of protection that cannot fire.
            if thermalLatchSaveFailed { return .backendFailure }
            // The battery step maps its own outcome. Previously only a nil
            // mutation with an error yielded 5, so a critical-battery release
            // that FAILED reported success — a protective action that did not
            // happen, announced as fine.
            switch batteryMutation {
            case .releaseFailed: return .backendFailure
            case .releaseRefused: return .refused
            case .released, .rearmWithheld, nil: break
            }
            // A critical-battery release that is followed by a failed
            // `pmset sleepnow` did not do its job: the Mac drains on. The
            // record is gone by then, so the next minute takes the fast path
            // and never retries — an exit 0 here would hide it for good.
            if let rc = sleepRC, rc != 0 { return .backendFailure }
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
    /// Proof-of-execution record, written at the END of every run (ADR 024 §5).
    /// It is what lets the CLI tell an agent that is merely registered from one
    /// that actually fires.
    public let heartbeatStore: BackstopHeartbeatStore
    /// `app.lock` probe (ADR 023 `AppLivenessLock`, shared-lock probe).
    public let appIsAlive: @Sendable () -> Bool
    /// The battery guard's operator kill switch (`LowBatteryGuardSettings`).
    ///
    /// The app already honours it: with the guard switched off it skips the
    /// battery step and still runs the session step
    /// (`AppMain.runLowBatteryTick`). The backstop is the SAME guard, so it must
    /// obey the same switch — otherwise an operator who turned the guard off
    /// would still get a `disablesleep 0` plus `pmset sleepnow` from launchd,
    /// one minute after saying no. Injected for the same reason every other
    /// system read is: so the rule is testable without touching this Mac.
    public let batteryGuardEnabled: @Sendable () -> Bool
    /// The thermal guard's operator kill switch (`ThermalGuardSettings`,
    /// ADR 025 — the sibling of `batteryGuardEnabled`).
    ///
    /// A session with no end time must be protected from HEAT even when the
    /// menu-bar app is gone: that is the exact argument that put the battery
    /// step in the backstop. The switch is honoured for the same reason too —
    /// an operator who turned the thermal guard off must not get a
    /// `disablesleep 0` plus `pmset sleepnow` from launchd a minute later.
    public let thermalGuardEnabled: @Sendable () -> Bool
    public var wallClock: @Sendable () -> Date

    public init(
        sessionService: SessionService,
        guardService: LowBatteryGuardService,
        lock: LidWriteLock = LidWriteLock(),
        auditLog: RecoveryAuditLog = RecoveryAuditLog(),
        heartbeatStore: BackstopHeartbeatStore = BackstopHeartbeatStore(),
        appIsAlive: @escaping @Sendable () -> Bool,
        batteryGuardEnabled: @escaping @Sendable () -> Bool = {
            LowBatteryGuardSettings.isEnabled()
        },
        thermalGuardEnabled: @escaping @Sendable () -> Bool = {
            ThermalGuardSettings.isEnabled()
        },
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionService = sessionService
        self.guardService = guardService
        self.lock = lock
        self.auditLog = auditLog
        self.heartbeatStore = heartbeatStore
        self.appIsAlive = appIsAlive
        self.batteryGuardEnabled = batteryGuardEnabled
        self.thermalGuardEnabled = thermalGuardEnabled
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
            sessionService: session,
            // ADR 025: the SAME thermal policy the app runs. A session with no
            // end time must be protected from heat even if the app crashed —
            // the argument that justified the battery step here.
            thermalService: ThermalGuardService.live(bootID: bootID,
                                                     sessionService: session))
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
    ///      exit 0 with no `pmset` call and no battery read, inside a lock it
    ///      takes and immediately releases (the CLI's proof of execution);
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
            latch: guardService.latchStore.load().latch,
            batteryGuardEnabled: batteryGuardEnabled(),
            thermalGuardEnabled: thermalGuardEnabled())
        let plan = RecoveryPolicy.plan(facts)
        let outcome: Outcome
        if !plan.needsWork {
            // 1 — nothing is ours and nothing is scheduled: no lock, no
            // `pmset`, no battery read. The proof this minute carries is
            // "the agent ran and did not fail" — deliberately NOT "a
            // protective section ran", which nothing on a virgin machine
            // could ever satisfy (see `runFreshness`).
            outcome = .nothingToDo
        } else if appIsAlive() {
            // 2 — the app is running: it owns enforcement, and the probe is free.
            outcome = .appAlive
        } else if let report = lock.tryWithLock({ lockedRun(plan: plan, recordBootID: record.bootID) }) {
            outcome = .completed(report)
        } else {
            // 3 — never queue behind the app or a CLI.
            outcome = .busy
        }
        // Proof of execution (ADR 024 §5), written for EVERY outcome —
        // including the fast path and a busy minute. A minute that legitimately
        // did nothing still proves the agent itself is running, which is what
        // the CLI needs before trusting it to end a session deadline. One small
        // atomic file, written AFTER the lock is released.
        writeHeartbeat(for: outcome, bootID: now.bootID)
        return outcome
    }

    /// Record that this agent ran, carrying the `rearmWithheld` episode flag so
    /// the audit stays once-per-episode (round 2 review).
    ///
    /// `nil` means this minute did not evaluate the battery at all (fast path,
    /// app alive, busy): the previous flag is carried forward untouched, so a
    /// busy minute in the middle of an episode does not re-audit it.
    private func writeHeartbeat(for outcome: Outcome, bootID: String) {
        let previous = heartbeatStore.load()
        // The `rearmWithheld` episode survives minutes that never evaluate the
        // battery (fast path, app alive, busy), so the log stays
        // once-per-episode instead of re-reporting on every no-op minute.
        let reported = outcome.rearmWithheldEpisode ?? previous?.rearmWithheldReported ?? false
        // A repeating failure keeps its key until the battery step RUNS again
        // and finds a different (or no) failure: a minute that never reached
        // the battery step (fast path, app alive, busy) must not clear the
        // memory, or the next failing minute would re-audit the same failure.
        //
        // `batteryStepRan` is what makes that distinction readable. Without
        // it, a run that reached the battery step and found the release healthy
        // carried `auditedFailureKey == nil` exactly like a run that never got
        // there, so the key survived a full recovery: a LATER failure with the
        // same reason matched it and was never audited at all (review round
        // 10). A healthy battery step therefore CLEARS the key; only a minute
        // that never evaluated the battery carries it forward.
        let auditedKey: String?
        if !outcome.batteryStepRan {
            auditedKey = previous?.lastAuditedFailureKey
        } else {
            auditedKey = outcome.auditedFailureKey
        }
        // Same tri-state for the session step: a minute with no session to
        // expire proved nothing about the retained-record failure, so it must
        // not forget it; a session step that ran and is no longer retained
        // clears it.
        let auditedSessionKey: String?
        if !outcome.sessionStepRan {
            auditedSessionKey = previous?.lastAuditedSessionFailureKey
        } else {
            auditedSessionKey = outcome.auditedSessionFailureKey
        }
        let saved = heartbeatStore.save(.init(
            at: wallClock(),
            bootID: bootID,
            exitCode: outcome.exitCode.rawValue,
            rearmWithheldReported: reported,
            lastAuditedFailureKey: auditedKey,
            lastAuditedSessionFailureKey: auditedSessionKey))
        guard !saved else { return }
        // Not fatal — the protective action already happened — but a heartbeat
        // that cannot be written silently breaks two things: the CLI refuses
        // timed sessions without saying why (it fails safe, but
        // undiagnosably), and `rearmWithheldReported` never persists, so every
        // minute of an episode re-audits and the log flood comes back.
        FileHandle.standardError.write(Data(
            ("[RunClosed] recover --backstop: heartbeat could not be written to "
             + "\(heartbeatStore.url.path) — the CLI will not trust the agent "
             + "until this succeeds\n").utf8))
    }

    /// The ONE `LidWriteLock` section. It must not take the lock again:
    /// `SessionService.step()` and `LowBatteryGuardService.protectiveStep()`
    /// both run on the caller's section by contract.
    private mutating func lockedRun(plan: RecoveryPolicy.Plan, recordBootID: String) -> Report {
        var report = Report(plan: plan)
        // The episode flag is read BEFORE this run's battery step, and only
        // meaningful when the battery step runs at all.
        let previous = heartbeatStore.load()
        let rearmAlreadyReported = previous?.rearmWithheldReported ?? false
        let auditedFailureKey = previous?.lastAuditedFailureKey

        // — Thermal step: the SAME policy the app runs (ADR 025), and it goes
        // FIRST for the same reason it does in the app's tick: heat kills
        // faster than the drain. A session with no end time must be protected
        // from heat even when the app crashed — exactly the argument that put
        // the battery step here.
        //
        // Its release ENDS the run: the flag is now off, so the battery step
        // would only observe `lidFlagOff`, and its re-arm branch must never
        // run for a machine that is still hot.
        if plan.thermal {
            let thermal = guardService.runThermalStep()
            report.thermalStepRan = true
            // Captured BEFORE the "does it govern?" branch, and deliberately:
            // a `.warn` tick does not govern the run, but it is exactly the
            // tick that writes `seriousSince` (the heads-up starts the clock).
            // Read inside the branch, an unwritable latch on a warn-only minute
            // went unreported — and that minute looks perfectly healthy while
            // the ten-minute release is already unreachable.
            report.thermalLatchSaveFailed = thermal?.latchSaveFailed ?? false
            if let thermal, LowBatteryGuardService.thermalGovernsTheTick(thermal) {
                report.thermalReason = thermal.evaluation.decision.reason
                report.thermalMutation = thermal.mutation
                report.thermalError = thermal.mutationError
                report.sleepAttempted = thermal.sleepAttempted
                report.sleepRC = thermal.sleepRC
                report.sessionEndedByHeat = thermal.sessionEndedByHeat
                // The thermal service audits its OWN file (`thermal_audit.jsonl`,
                // one line per action, deduped by the latch). The recovery log
                // gets the line that belongs to the BACKSTOP: what this agent
                // did because the app was not there to do it.
                if thermal.mutation != nil || thermal.sessionEndedByHeat {
                    audit(.init(
                        ts: timestamp(),
                        bootID: sessionService.continuous.bootID,
                        step: "thermalRelease",
                        outcome: thermal.mutation?.rawValue ?? "sessionEnded",
                        reason: thermal.evaluation.decision.reason.rawValue,
                        detail: thermal.sessionEndedByHeat ? "session ended by heat" : nil,
                        recordBootID: recordBootID.isEmpty ? nil : recordBootID,
                        error: thermal.mutationError,
                        sleepRC: thermal.sleepRC))
                    report.audited = true
                }
                return report
            }
        }

        // — Session step: expire a due session (`.sessionRecovery` for its own
        // previous-boot record), or reconcile an orphan. Same decisions as the
        // app's tick; no second copy.
        if plan.session {
            let step = sessionService.step()
            report.session = step
            // Set BEFORE the decision, so a `nil` key below means "measured,
            // nothing repeating" rather than "the step never ran".
            report.sessionStepRan = true
            let wrote = auditSession(step, recordBootID: recordBootID,
                                     previousKey: previous?.lastAuditedSessionFailureKey)
            switch step.expiry {
            case .retained(let message):
                // Carried only while the SAME record keeps failing the SAME
                // way; any other outcome leaves this nil, which clears the key.
                report.auditedSessionFailureKey =
                    "sessionExpiryRetained:\(recordBootID):\(message)"
                // A deduped line still means the deadline was NOT enforced: the
                // failure is real whether or not it was written again, and the
                // exit code already reports it.
                report.audited = true
            case .ended:
                report.audited = true
            default:
                if wrote { report.audited = true }
            }
        }

        // — Battery step: only while our record claims the flag. The decision
        // is computed from LIVE values inside the lock (the file-only fast path
        // had no battery reading), so a stale reading never drives a release.
        //
        // It runs even when the session step failed: the two are independent
        // protections, and a failed release is exactly the moment the battery
        // rule matters most. The exit code aggregates both.
        guard plan.battery else { return report }
        // Set BEFORE the battery step: from here on, a `nil` `auditedFailureKey`
        // in this report is a measurement ("no repeating failure right now"),
        // not an absence of measurement.
        report.batteryStepRan = true
        let battery = guardService.protectiveStep()
        report.batteryReason = battery.decision.reason
        report.batteryMutation = battery.mutation
        report.batteryError = battery.mutationError
        report.sleepAttempted = battery.sleepAttempted
        report.sleepRC = battery.sleepRC
        switch battery.mutation {
        case .released, .releaseFailed, .releaseRefused:
            // `releaseFailed` is the one outcome that REPEATS: a persistent
            // failure (a stale sudoers rule, a `pmset` refused in the agent's
            // context) holds the same condition every 60 s and would write
            // 1 440 identical lines a day — the flood the "never on a no-op
            // minute" rule exists to prevent. So a repeating failure is
            // audited once per (reason) episode, tracked in the heartbeat, and
            // a NEW reason or a recovery always writes. `released` and
            // `releaseRefused` are terminal by construction: they stop the
            // condition, so there is nothing to dedupe (review round 9).
            if battery.mutation == .releaseFailed {
                let key = "batteryReleaseFailed:\(battery.decision.reason.rawValue)"
                if auditedFailureKey != key {
                    auditBattery(battery, recordBootID: recordBootID)
                    report.audited = true
                }
                report.auditedFailureKey = key
            } else {
                auditBattery(battery, recordBootID: recordBootID)
                report.audited = true
            }
        case .rearmWithheld:
            // The app owes a re-arm and the backstop will not do it. Recording
            // it keeps "nothing happened" from being the only trace — but ONCE
            // PER EPISODE: the condition (our record claims the flag, the flag
            // reads OFF, a re-arm is owed, AC above 15 %) holds for every
            // minute it lasts, so auditing each minute would be a flood. The
            // flag lives in the heartbeat, which survives process restarts.
            report.rearmWithheldEpisode = true
            if !rearmAlreadyReported {
                audit(.init(
                    ts: timestamp(),
                    bootID: sessionService.continuous.bootID,
                    step: "batteryRearm",
                    outcome: "withheld",
                    reason: battery.decision.reason.rawValue,
                    detail: "a re-arm is the app's; the backstop never turns the flag on (reported once per episode)",
                    chargePercent: battery.chargePercent,
                    minutesRemaining: battery.minutesRemaining,
                    recordBootID: recordBootID.isEmpty ? nil : recordBootID))
                report.audited = true
            }
        case .none:
            // Out of the episode: the next rearmWithheld run reports again.
            break
        }
        return report
    }

    /// The JSON body `recover --backstop` prints, plus the exit code.
    ///
    /// It lives HERE, not in `main.swift`, because it is the command the
    /// LaunchAgent actually runs: a test that asserts `Report.exitCode` while
    /// the CLI prints something else proves nothing about the agent. The CLI is
    /// a thin printer over this.
    public static func describe(_ outcome: Outcome, bootID: String) -> (json: [String: Any], exitCode: Int32) {
        var obj: [String: Any] = [
            "schemaVersion": 1,
            "bootID": bootID,
            "action": "recover",
            "backstop": true,
            "outcome": outcome.rawValue,
            "exitCode": Int(outcome.exitCode.rawValue),
        ]
        if case .completed(let report) = outcome {
            obj["ownership"] = report.plan.ownership.rawValue
            obj["steps"] = [
                "session": report.plan.session,
                "sessionDue": report.plan.sessionDue,
                "battery": report.plan.battery,
                "thermal": report.plan.thermal,
            ]
            // ADR 025: present only when the thermal step governed this run, so
            // a machine that never overheats keeps the ADR 024 report byte for
            // byte.
            if report.thermalStepRan {
                obj["thermalStepRan"] = true
            }
            if let reason = report.thermalReason {
                obj["thermalReason"] = reason.rawValue
                obj["thermalMutation"] = report.thermalMutation?.rawValue as Any? ?? NSNull()
                obj["thermalError"] = report.thermalError as Any? ?? NSNull()
                obj["sessionEndedByHeat"] = report.sessionEndedByHeat
                obj["thermalLatchSaveFailed"] = report.thermalLatchSaveFailed
            }
            if let step = report.session {
                obj["sessionExpiry"] = String(describing: step.expiry)
                obj["sessionReconciled"] = step.reconciled.map { String(describing: $0) } as Any? ?? NSNull()
            }
            obj["batteryReason"] = report.batteryReason?.rawValue as Any? ?? NSNull()
            obj["batteryMutation"] = report.batteryMutation?.rawValue as Any? ?? NSNull()
            obj["batteryError"] = report.batteryError as Any? ?? NSNull()
            obj["sleepAttempted"] = report.sleepAttempted
            obj["sleepRC"] = report.sleepRC as Any? ?? NSNull()
            obj["audited"] = report.audited
        }
        return (obj, outcome.exitCode.rawValue)
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
    ///
    /// `previousKey` is the session-failure key already audited, and
    /// `recordBootID` doubles as the episode identity for a retained record.
    /// `.retained` is the only REPEATING outcome — the record stays so the next
    /// minute retries, which is right, but the same line would then land 1 440
    /// times a day. Same once-per-episode rule as the battery step (review
    /// round 15). A different error message is a different episode and always
    /// writes, so a changed failure is never hidden behind the old one.
    @discardableResult
    private mutating func auditSession(_ step: SessionService.StepOutcome,
                                       recordBootID: String,
                                       previousKey: String?) -> Bool {
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
            // The key names the episode: the same record failing the same way.
            let key = "sessionExpiryRetained:\(recordBootID):\(message)"
            if previousKey == key { return false }
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
