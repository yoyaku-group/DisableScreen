import Foundation
import RunClosedCore
import RunClosedPersistence

/// Backend for the single "sleep now" primitive of the low-battery guard.
public protocol SystemSleeper: Sendable {
    /// Ask macOS to sleep now. Returns the exit status + merged output.
    func sleepNow() -> (rc: Int32, output: String?)
}

/// Live sleeper: `/usr/bin/pmset sleepnow` (public CLI, no root needed for
/// the console user). With `hibernatemode 3` the sleep image is written to
/// disk, so a battery that keeps draining ends in hibernation, not a hard
/// power-off — every process survives.
public struct PMSetSleeper: SystemSleeper {
    public init() {}

    public func sleepNow() -> (rc: Int32, output: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (-1, "Process fork failed: \(error)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus, (text?.isEmpty ?? true) ? nil : text)
    }
}

/// Kill switch (rules/49): `defaults write com.benjaminbelaga.RunClosed
/// lowBatteryGuardEnabled -bool false` disables the guard without a rebuild;
/// absent key = enabled.
public enum LowBatteryGuardSettings {
    public static let suiteName = "com.benjaminbelaga.RunClosed"
    public static let enabledKey = "lowBatteryGuardEnabled"

    public static func isEnabled() -> Bool {
        // Inside the bundle (app AND embedded `runclosed-cli`) the main bundle
        // id IS the suite: `UserDefaults(suiteName: <own id>)` is rejected by
        // Foundation ("does not make sense and will not work", measured on the
        // built bundle) — the standard domain is the same plist.
        if Bundle.main.bundleIdentifier == suiteName {
            return isEnabled(defaults: .standard)
        }
        return isEnabled(defaults: UserDefaults(suiteName: suiteName))
    }

    public static func isEnabled(defaults: UserDefaults?) -> Bool {
        guard let d = defaults, d.object(forKey: enabledKey) != nil else { return true }
        return d.bool(forKey: enabledKey)
    }
}

/// Executes `LowBatteryPolicy` decisions (ADR 022):
///
///   evaluate : battery readback + `pmset -g` flag + ownership record → policy
///   tick     : evaluate → act → persist the latch from the OUTCOME
///     releaseAndSleep : `LidMutationService.setEnabled(false, .automatic)`
///                       (B1 + B2 ownership gate unchanged) → verified →
///                       latch `releasedByGuard` → audit → `pmset sleepnow`;
///                       for `emergencyStaleOwnership` the initiator is
///                       `.lowBatteryEmergency` (our own record from a
///                       previous boot — the service re-checks it)
///     rearm           : `setEnabled(true, .automatic)` once back on AC and
///                       charge > 15% (hysteresis)
///     warn            : nothing here — the caller notifies the operator
///
/// UI-free and unit-testable with fakes (lid assertion, sleeper, battery).
public struct LowBatteryGuardService {

    public var lidService: LidMutationService
    public let latchStore: LowBatteryLatchStore
    public let batteryProvider: @Sendable () -> BatteryState
    public var sleeper: any SystemSleeper
    /// Serialises the whole tick with the operator paths (popup, CLI).
    public let lock: LidWriteLock
    /// Persisted audit line for every guard mutation (ADR 022).
    public let auditLog: LowBatteryAuditLog
    /// Optional timed-session layer (ADR 023). `nil` = ADR 022 behaviour
    /// unchanged, byte for byte: no session file is read, no extra branch runs.
    /// When present, the SAME locked tick (one `LidWriteLock` section) also
    /// expires a due session, pauses it on a battery release, and resumes it
    /// on the re-arm.
    public var sessionService: SessionService?
    /// Optional thermal step (ADR 025). `nil` = ADR 022/023 behaviour
    /// unchanged. When present it runs FIRST in the same section: heat kills
    /// faster than the drain, and a machine that overheated must be released
    /// before the battery step gets to read the flag.
    public var thermalService: ThermalGuardService?
    /// Optional lid-close actions (ADR 026). `nil` = ADR 022/023/025 behaviour
    /// unchanged. When present it runs LAST in the same section: it is the one
    /// step whose job is to UNDO what it did, so it must run after the steps
    /// that can end a session or release the flag — a release must not leave
    /// the Mac muted with an app frozen.
    ///
    /// It also takes no lock of its own (same contract as the thermal step).
    public var lidCloseActions: LidCloseActionService?
    /// The lid-close readings and settings, resolved per tick so a change made
    /// in the menu bar takes effect on the next tick without a restart.
    public var lidCloseReadings: (@Sendable () -> LidCloseActionService.Readings)?

    public init(
        lidService: LidMutationService,
        latchStore: LowBatteryLatchStore,
        batteryProvider: @escaping @Sendable () -> BatteryState,
        sleeper: any SystemSleeper,
        lock: LidWriteLock = LidWriteLock(),
        auditLog: LowBatteryAuditLog = LowBatteryAuditLog(),
        sessionService: SessionService? = nil,
        thermalService: ThermalGuardService? = nil,
        lidCloseActions: LidCloseActionService? = nil,
        lidCloseReadings: (@Sendable () -> LidCloseActionService.Readings)? = nil
    ) {
        self.lidService = lidService
        self.latchStore = latchStore
        self.batteryProvider = batteryProvider
        self.sleeper = sleeper
        self.lock = lock
        self.auditLog = auditLog
        self.sessionService = sessionService
        self.thermalService = thermalService
        self.lidCloseActions = lidCloseActions
        self.lidCloseReadings = lidCloseReadings
    }

    public struct Evaluation: Equatable, Sendable {
        public var battery: BatteryState
        public var input: LowBatteryPolicy.Input
        public var decision: LowBatteryPolicy.Decision
        public var latchBefore: LowBatteryPolicy.Latch
        public var latchAfter: LowBatteryPolicy.Latch
    }

    public enum MutationOutcome: String, Codable, Sendable, Equatable {
        /// `disablesleep 0` verified by readback.
        case released
        /// Refused before any write (B1 unknown prior, B2 not owned, no-op).
        case releaseRefused
        /// The write or its readback failed (e.g. sudoers rule missing).
        case releaseFailed
        case rearmed
        /// The flag was already ON again (a human re-enabled it).
        case rearmAlreadyOn
        case rearmFailed
    }

    public struct TickOutcome: Equatable, Sendable {
        public var evaluation: Evaluation
        public var mutation: MutationOutcome?
        public var mutationError: String?
        public var sleepAttempted: Bool = false
        public var sleepRC: Int32?
        public var sleepOutput: String?
        /// Whether the caller should notify about `mutation`. Failures are
        /// notified once per discharge episode, never every 30 s.
        public var shouldNotify: Bool = false
        /// What the session step did this tick (ADR 023). `nil` when no session
        /// layer is wired or nothing happened.
        public var session: SessionService.ExpiryOutcome?
        /// Set when the operator should be told a session ended by itself, at
        /// most once (the record is gone afterwards). `false` for
        /// `.flagLeftOn`: the session ended but the Mac is still awake.
        public var sessionEndedNaturally: Bool = false
        /// Set when the flag was re-armed on AC for a still-live session, so
        /// the menu bar can refresh without polling the record.
        public var sessionResumed: Bool = false
        /// Set when the session step reconciled a record whose flag reads OFF
        /// (ADR 023): cleared as an orphan, or a lost battery pause restored.
        public var sessionReconciled: SessionService.ReconcileOutcome?
        /// The thermal step's result (ADR 025), when one is wired. `nil` on a
        /// machine with no thermal layer, which keeps ADR 022/023 behaviour
        /// byte for byte.
        public var thermal: ThermalGuardService.TickOutcome?
        /// The lid-close actions' result (ADR 026), when one is wired. `nil`
        /// on a machine with no lid-close layer.
        public var lidClose: LidCloseActionService.TickOutcome?
        /// Whether the BATTERY step ran in this tick.
        ///
        /// `false` for `thermalTick()` — the tick the app runs with the battery
        /// guard switched off. The evaluation it carries is still a real
        /// readback (the popup and the bar render it), but no battery decision
        /// was ACTED on, so the caller must not announce one: an operator who
        /// turned the battery guard off would otherwise still get its
        /// "Battery low" notification from a tick that was only looking at
        /// heat.
        public var batteryStepRan: Bool = true
    }

    /// Read-only evaluation: no mutation, no persistence write. Used by
    /// `runclosed low-battery status` and as the first half of `tick()`.
    public func evaluate() -> Evaluation {
        let battery = batteryProvider()
        let flag = lidService.priorProvider()
        let rec = lidService.store.load()
        let ownership = LowBatteryPolicy.LidOwnership.classify(
            recordBootID: rec.bootID,
            recordOwnedEnabled: rec.ownedEnabled,
            currentBootID: lidService.bootID)
        let input = LowBatteryPolicy.Input(
            onBattery: battery.onBattery,
            chargePercent: battery.chargePercent,
            minutesRemaining: battery.minutesRemaining,
            lidFlag: flag,
            ownership: ownership,
            acDraining: LowBatteryPolicy.Input.acDraining(
                onBattery: battery.onBattery, currentMilliamps: battery.currentMilliamps))
        let latch = latchStore.load().latch
        let (decision, next) = LowBatteryPolicy.step(input, latch: latch)
        return Evaluation(battery: battery, input: input, decision: decision,
                          latchBefore: latch, latchAfter: next)
    }

    /// One guard tick (the menu-bar app calls it every 30 s, off-main).
    /// Read → decide → act → save runs entirely under `LidWriteLock`, so an
    /// operator command can neither interleave with a mutation in flight nor
    /// have its latch change overwritten by a stale save.
    @discardableResult
    public mutating func tick() -> TickOutcome {
        return lock.withLock { lockedTick() }
    }

    /// The tick the app runs when the BATTERY guard is switched off but the
    /// thermal one is on (ADR 025): one `LidWriteLock` section, the thermal
    /// step first, then the session step — never the battery step.
    ///
    /// Without it the two kill switches would be coupled in the wrong
    /// direction: turning the battery guard off would also switch heat
    /// protection off, which is exactly the pairing the operator did not ask
    /// for (ADR 024's addendum made the same argument for the battery step in
    /// the backstop).
    @discardableResult
    public mutating func thermalTick() -> TickOutcome {
        return lock.withLock { lockedThermalTick() }
    }

    private mutating func lockedThermalTick() -> TickOutcome {
        let thermal = runThermalStep()
        if let thermal, Self.thermalGovernsTheTick(thermal) {
            return thermalOutcome(thermal)
        }
        let sessionStep = sessionService?.step()
        var outcome = TickOutcome(evaluation: evaluate())
        outcome.thermal = thermal
        // No battery decision was taken here: the guard is switched off.
        outcome.batteryStepRan = false
        outcome.session = sessionStep?.expiry
        outcome.sessionReconciled = sessionStep?.reconciled
        if case .ended(let end)? = sessionStep?.expiry {
            outcome.sessionEndedNaturally = end.stopsKeepingAwake
        }
        outcome.lidClose = runLidCloseStep()
        return outcome
    }

    /// The tick outcome for a thermal step that governed it. Read-only, and
    /// evaluated AFTER the release: the battery fields describe the flag as the
    /// thermal step left it, which is what the popup and the bar will show.
    ///
    /// One helper for the app's two locked ticks, so the mapping of a thermal
    /// mutation onto the battery vocabulary cannot drift between them: the
    /// three protective outcomes are exactly the three the battery release
    /// produces, and `releaseRefused` keeps its own meaning (nothing was
    /// written).
    private mutating func thermalOutcome(
        _ thermal: ThermalGuardService.TickOutcome
    ) -> TickOutcome {
        var outcome = TickOutcome(evaluation: evaluate())
        outcome.thermal = thermal
        outcome.mutation = thermal.mutation.map {
            switch $0 {
            case .released: return .released
            case .releaseFailed: return .releaseFailed
            case .releaseRefused: return .releaseRefused
            }
        }
        outcome.mutationError = thermal.mutationError
        outcome.sleepAttempted = thermal.sleepAttempted
        outcome.sleepRC = thermal.sleepRC
        outcome.sleepOutput = thermal.sleepOutput
        outcome.shouldNotify = thermal.shouldNotify
        // A heat release ends the session; the caller tells the operator
        // through the thermal notice, not a second "session ended" one.
        outcome.sessionEndedNaturally = false
        outcome.batteryStepRan = false
        outcome.lidClose = runLidCloseStep()
        return outcome
    }

    /// The lid-close step (ADR 026): apply while the three conditions hold,
    /// undo as soon as they stop.
    ///
    /// Runs LAST in the section, and for a reason that is the whole safety
    /// design of the lot: it is the step whose job is to UNDO, so it must see
    /// the session record the other steps just acted on. A tick that released
    /// the flag must undo the sound, not leave the Mac muted.
    ///
    /// Takes no lock (the caller holds `LidWriteLock`). Returns `nil` when no
    /// lid-close layer is wired, which keeps ADR 022/023/025 behaviour
    /// unchanged.
    public mutating func runLidCloseStep() -> LidCloseActionService.TickOutcome? {
        guard var service = lidCloseActions, let readings = lidCloseReadings else { return nil }
        // Read the session fresh: the thermal or session step above may have
        // just finished it, and a finished session is exactly the moment the
        // undo has to happen.
        var r = readings()
        // The service's answer WINS, including nil: a session it just closed
        // must not be resurrected from a readings closure that was captured
        // before the close, or the step would APPLY effects for a session that
        // no longer exists instead of undoing them (gate finding, `Une session
        // supprimée peut être remplacée par une lecture périmée`).
        if let sessionService {
            r.session = sessionService.load()
        }
        let outcome = service.step(readings: r)
        lidCloseActions = service
        return outcome
    }

    /// The unconditional undo (ADR 026), for a caller about to make the Mac
    /// sleep or quit. It does not consult the conditions: if anything is
    /// journaled, it is reversed.
    public mutating func runLidCloseUndo() -> LidCloseActionService.TickOutcome? {
        guard var service = lidCloseActions else { return nil }
        let outcome = service.undoAll()
        lidCloseActions = service
        return outcome
    }

    /// The thermal step, for a caller that already holds `LidWriteLock` (the
    /// app's shared tick, the ADR 024 backstop's one section). Takes no lock:
    /// `withLock` opens a new fd, so nesting it would deadlock.
    ///
    /// Returns `nil` when no thermal layer is wired (ADR 022/023 behaviour
    /// unchanged), so the battery and session steps run exactly as before.
    public mutating func runThermalStep() -> ThermalGuardService.TickOutcome? {
        guard var thermal = thermalService else { return nil }
        let outcome = thermal.step()
        thermalService = thermal
        return outcome
    }

    /// Does this thermal outcome make the rest of the tick redundant?
    ///
    /// `true` in exactly two cases: the step ATTEMPTED a release (the flag is
    /// now off, so the battery step would only read `lidFlagOff` — and its
    /// re-arm branch could turn the flag back ON for a machine that is still
    /// hot, which the thermal rule must never allow), or it ended the session
    /// (there is no record left to expire).
    ///
    /// A thermal WARNING does NOT govern the tick: telling the operator the Mac
    /// is hot must not suppress the independent battery protection — a machine
    /// at 4 % must still release, hot or not. And an inert thermal minute —
    /// `nominal`, or hot with the lid open — leaves the rest of the tick
    /// untouched, so ADR 022/023 behaviour is unchanged whenever heat has
    /// nothing to say.
    ///
    /// The one thing heat must block is the RE-ARM, and that is enforced where
    /// the re-arm is decided (`lockedTick`), not by starving the whole battery
    /// step: blocking the step wholesale would also block the critical release,
    /// which is the opposite of protective (review round 2).
    public static func thermalGovernsTheTick(
        _ outcome: ThermalGuardService.TickOutcome
    ) -> Bool {
        outcome.mutation != nil || outcome.sessionEndedByHeat
    }

    /// Is the machine hot in the one configuration where the thermal rule is
    /// allowed to act — lid closed, no display, and the flag provably ours?
    ///
    /// Used to VETO a battery re-arm: re-enabling `disablesleep` on a hot,
    /// enclosed Mac recreates the exact condition the thermal policy exists to
    /// escape, and it would do so through a branch that never consults heat.
    /// A machine that is hot but NOT enclosed is left alone — air circulates,
    /// the battery rule wins.
    public static func thermalVetoesRearm(_ outcome: ThermalGuardService.TickOutcome) -> Bool {
        outcome.evaluation.decision.state.isHot
            && outcome.evaluation.input.isEnclosed
            && outcome.evaluation.input.ownership == .ownedThisBoot
    }

    /// What a protective-only caller did. There is no `rearmed` case: the
    /// re-arm is the app's, so a decision that asks for one is WITHHELD and
    /// reported as such.
    public struct ProtectiveOutcome: Equatable, Sendable {
        public var decision: LowBatteryPolicy.Decision
        public var chargePercent: Int?
        public var minutesRemaining: Int?
        public var mutation: ProtectiveMutation?
        public var mutationError: String?
        public var sleepAttempted = false
        public var sleepRC: Int32?

        public init(decision: LowBatteryPolicy.Decision, chargePercent: Int?,
                    minutesRemaining: Int?) {
            self.decision = decision
            self.chargePercent = chargePercent
            self.minutesRemaining = minutesRemaining
        }
    }

    public enum ProtectiveMutation: String, Equatable, Sendable {
        case released
        case releaseRefused
        case releaseFailed
        /// The policy wanted a re-arm; a protective-only caller never performs
        /// one, so the debt is left to the app (ADR 024).
        case rearmWithheld
    }

    /// The battery step for a caller that may only PROTECT (ADR 024).
    ///
    /// Same policy, same ownership gate, same latch and audit discipline as
    /// `tick()` — the only difference is what it refuses to do:
    ///
    /// - it NEVER enables the flag: `.rearm` becomes `.rearmWithheld`, and the
    ///   persisted debt stays exactly where the app will find it;
    /// - it does not run the session step. The backstop runs that itself,
    ///   once, in the same lock section, so running it here too would be a
    ///   second decision on the same record;
    /// - it takes no lock. The caller holds `LidWriteLock` (the backstop's
    ///   one section).
    ///
    /// The release itself goes through the same branch `tick()` uses
    /// (`performRelease`), so there is one rule and not two.
    public mutating func protectiveStep() -> ProtectiveOutcome {
        let evaluation = evaluate()
        var outcome = ProtectiveOutcome(
            decision: evaluation.decision,
            chargePercent: evaluation.input.chargePercent,
            minutesRemaining: evaluation.input.minutesRemaining)
        var record = latchStore.load()
        let before = record
        record.latch = evaluation.latchAfter

        switch evaluation.decision.action {
        case .none, .warn:
            break
        case .rearm:
            outcome.mutation = .rearmWithheld
            outcome.mutationError = "a re-arm is the app's; the backstop never turns the flag on"
        case .releaseAndSleep:
            // Captured here, before the write, so the guard's own audit line
            // describes the record the decision was based on.
            let recordBootIDBefore = lidService.store.load().bootID
            var tick = TickOutcome(evaluation: evaluation)
            performRelease(evaluation: evaluation, record: &record, outcome: &tick,
                           recordBootIDBefore: recordBootIDBefore, protective: true)
            outcome.mutation = tick.mutation.map {
                switch $0 {
                case .released: return .released
                case .releaseFailed: return .releaseFailed
                default: return .releaseRefused
                }
            }
            outcome.mutationError = tick.mutationError
            outcome.sleepAttempted = tick.sleepAttempted
            outcome.sleepRC = tick.sleepRC
        }
        // The backstop shows NO notification, so it must not consume the
        // operator's warnings on the app's behalf. `LowBatteryPolicy` sets
        // `warnedLow` on `.warn`, and a refused release sets `warnedCritical`;
        // persisting those would make the app's next tick answer
        // `.alreadyWarned` and the low-battery (or critical-not-owned) warning
        // would never be shown at all — the one case where the operator most
        // needs to be told. `failedReleaseSleepTried` is the same story: it
        // suppresses the app's notify-once.
        //
        // Only the re-arm debt (`releasedByGuard` / `releasedBootID`) is this
        // caller's to write: that is the app's signal to re-enable the flag,
        // not a claim that anyone was informed.
        //
        // `protectiveSleepTried` is the ONE latch this caller may write: it is
        // the backstop's own "I already slept for this failure" memory. Without
        // it the sleep-once guard was erased here on every run, so a
        // persistently failing release put the Mac to sleep every 60 s — even
        // right after the operator woke it (review round 10). Separate from
        // `failedReleaseSleepTried` precisely because that one doubles as the
        // app's notify latch, which must stay untouched.
        //
        // Restoring is not a blanket copy: the policy also CLEARS these latches
        // once the charge is back above the warn band, and copying `before`
        // back would silently undo that reset. A machine that charged while the
        // app was not running would keep `warnedLow`/`warnedCritical` set
        // forever, so the app's first warning of the NEXT discharge would be
        // answered `.alreadyWarned` and never shown — the same silent silencing
        // this restore exists to prevent, just one episode later (review round
        // 13). `&&` says exactly the right thing per field: a SET by this run
        // is suppressed, a CLEAR by the policy goes through.
        record.latch.warnedLow = before.latch.warnedLow && record.latch.warnedLow
        record.latch.warnedCritical = before.latch.warnedCritical && record.latch.warnedCritical
        record.latch.failedReleaseSleepTried =
            before.latch.failedReleaseSleepTried && record.latch.failedReleaseSleepTried
        if record != before {
            latchStore.save(record)
        }
        return outcome
    }

    private mutating func lockedTick() -> TickOutcome {
        // ADR 025 — heat is evaluated FIRST, in this same section: it kills
        // faster than the drain. The step takes no lock of its own (this is the
        // app's single section). A tick where heat governs stops here: the
        // battery step would otherwise read a flag we have just released and
        // its re-arm branch could turn it back ON for a machine that is still
        // hot — the one thing this policy must never allow.
        let thermal = runThermalStep()
        if let thermal, Self.thermalGovernsTheTick(thermal) {
            return thermalOutcome(thermal)
        }
        // ADR 023 — session expiry runs FIRST, inside this same lock section:
        // a session whose deadline passed must never be re-armed by the very
        // tick that noticed the deadline. It is a separate step from the
        // battery one so the ADR 022 decision below is computed from an
        // observation taken AFTER any release.
        // The same step also reconciles a running session whose flag reads
        // OFF, before the battery step reads the latch it may have cleared.
        let sessionStep = sessionService?.step()
        let sessionExpiry = sessionStep?.expiry
        let evaluation = evaluate()
        // Which boot wrote the ownership record, captured before any write
        // (an emergency release replaces a stale record with this boot's).
        let recordBootIDBefore = lidService.store.load().bootID
        var outcome = TickOutcome(evaluation: evaluation)
        // Carried, never merged: a thermal WARNING must reach the operator
        // without displacing whatever the battery step decided. A thermal
        // RELEASE never gets this far (it governs the tick above).
        outcome.thermal = thermal
        outcome.session = sessionExpiry
        outcome.sessionReconciled = sessionStep?.reconciled
        var record = latchStore.load()
        let before = record
        record.latch = evaluation.latchAfter

        if case .ended(let end)? = sessionExpiry {
            // A finished session owes no re-arm: drop any pending one so the
            // guard cannot flip the flag back on for a deadline that is gone
            // (ADR 023 §4). `SessionService.finish` already cleared the latch
            // on disk; this keeps the in-memory copy from re-saving it.
            record.latch = record.latch.recordingRearm()
            outcome.sessionEndedNaturally = end.stopsKeepingAwake
        }

        switch evaluation.decision.action {
        case .none, .warn:
            break

        case .releaseAndSleep:
            performRelease(evaluation: evaluation, record: &record, outcome: &outcome,
                           recordBootIDBefore: recordBootIDBefore)

        case .rearm:
            // ADR 025 — a hot, ENCLOSED machine must never get its flag back.
            // Re-enabling `disablesleep` here would recreate the exact
            // condition the thermal policy exists to escape, through a branch
            // that never consults heat: the ten-minute grace period would
            // become ten minutes during which the battery rule can undo the
            // thermal one. Checked BEFORE the session rules because heat
            // outranks a pending re-arm debt — the debt survives, it is simply
            // not paid while the machine cannot cool (review round 2).
            if let thermal, Self.thermalVetoesRearm(thermal) {
                outcome.mutation = nil
                outcome.mutationError = "re-arm withheld: the Mac is hot with the lid closed "
                    + "and no display attached"
                break
            }
            // ADR 023 §4: re-arm only while the session is still valid (not
            // due) AND on the boot that owns it. With no session the answer is
            // `true` and this is exactly the ADR 022 path.
            if let session = sessionService, !session.allowsRearm() {
                // The debt belonged to a timed session that can no longer use
                // it (due, or from another boot). Void it once instead of
                // refusing it again on every tick.
                outcome.mutation = nil
                outcome.mutationError = "re-arm withheld: session no longer valid (due or from another boot)"
                record.latch = record.latch.recordingRearm()
                break
            }
            let result = lidService.setEnabled(true, initiator: .automatic)
            switch result {
            case .success(let op) where op.state == .verified:
                outcome.mutation = .rearmed
                outcome.shouldNotify = true
                record.latch = record.latch.recordingRearm()
                outcome.sessionResumed = sessionService?.resumeAfterRearm() ?? false
            case .failure(.noChangeRequested(target: true)):
                outcome.mutation = .rearmAlreadyOn
                record.latch = record.latch.recordingRearm()
                outcome.sessionResumed = sessionService?.resumeAfterRearm() ?? false
            case .success(let op):
                outcome.mutation = .rearmFailed
                outcome.mutationError = op.error ?? "rearm not verified (state=\(op.state.rawValue))"
            case .failure(let error):
                // Keep the latch: retried on the next tick (B3).
                outcome.mutation = .rearmFailed
                outcome.mutationError = String(describing: error)
            }
        }

        // ADR 023 §4: a battery pause ends when the flag is ON and ours again,
        // whichever path turned it back on. Observed before this tick's own
        // writes; a release in this tick keeps the pause.
        if outcome.mutation != .released, !outcome.sessionResumed,
           evaluation.input.lidFlag == true, evaluation.input.ownership == .ownedThisBoot {
            outcome.sessionResumed = sessionService?.resumeIfFlagIsBack() ?? false
        }

        if record != before {
            latchStore.save(record)
        }
        // Audit: successful re-arms, and failures once per episode (the
        // release itself was audited before the sleep request).
        if let m = outcome.mutation, m != .released, m == .rearmed || outcome.shouldNotify {
            audit(outcome, evaluation: evaluation, recordBootID: recordBootIDBefore)
        }
        // ADR 026 — LAST, after every step that could end the session or
        // release the flag: this step's job is to keep the sound and the apps
        // in step with the session the steps above just changed.
        //
        // But NEVER re-APPLY in a tick that just tried to sleep the Mac: the
        // release may have failed and left the session active, and applying
        // again would UNDO the protective restore that `attemptSleep` performed
        // moments earlier (gate finding, `The final policy step can reapply
        // effects after protective sleep`). A sleep attempt means "undo only".
        if outcome.sleepAttempted {
            // The protective undo ALREADY ran inside `attemptSleep` and left a
            // real result (resumed pids, `changed`). Running `undoAll` again
            // here reads the now-cleared journal and returns `nothingToDo`,
            // OVERWRITING that result — so callers lost the resumed pids and the
            // changed signal and never refreshed (gate finding, `Final undo
            // overwrites the protective undo's result`). Keep what happened.
            // `nil` means no lid-close layer was wired, which needs no marker;
            // otherwise the protective undo's own result stays as the outcome.
        } else {
            outcome.lidClose = runLidCloseStep()
        }
        return outcome
    }

    /// The ONE critical-battery release branch, shared by `lockedTick()` (the
    /// app) and `protectiveStep()` (the ADR 024 backstop), so the two callers
    /// cannot drift apart: journal-with-outcome, pause the session, persist the
    /// re-arm debt BEFORE the sleep, audit before the sleep, then `sleepnow`.
    ///
    /// The only caller-specific input is the initiator, which the policy
    /// already decided (`emergencyStaleOwnership` widens B2 to our own record
    /// from a previous boot; `LidMutationService` re-checks it).
    /// `recordBootIDBefore` is passed IN rather than read here: `lockedTick`
    /// must capture it BEFORE the session step, which can clear or rewrite
    /// `owned_lid.json` on the same tick. Reading it inside the helper would
    /// record, in the low-battery audit line, the ownership record as it stood
    /// AFTER the session step instead of the one the battery decision was
    /// actually based on.
    private mutating func performRelease(evaluation: Evaluation,
                                         record: inout LowBatteryLatchStore.Record,
                                         outcome: inout TickOutcome,
                                         recordBootIDBefore: String,
                                         protective: Bool = false) {
        let initiator: LidMutationService.Initiator =
            evaluation.decision.reason == .emergencyStaleOwnership ? .lowBatteryEmergency : .automatic
        let result = lidService.setEnabled(false, initiator: initiator)
        switch result {
        case .success(let op) where op.state == .verified:
            outcome.mutation = .released
            outcome.shouldNotify = true
            record.latch = record.latch.recordingRelease()
            record.releasedBootID = lidService.bootID
            // ADR 023 §4: a low-battery release PAUSES the session instead
            // of ending it — the operator's deadline is not the battery's
            // to cancel, and the re-arm may revive it. A pause that
            // fails to save is restored by the next tick's reconciliation
            // (flag OFF + re-arm debt pending = a battery pause).
            sessionService?.pauseForBattery()
            // Persist the re-arm debt and the audit line BEFORE asking
            // for sleep: the Mac may go down right after `sleepnow`.
            latchStore.save(record)
            audit(outcome, evaluation: evaluation, recordBootID: recordBootIDBefore)
            // ADR 026: the lid-close actions are undone BEFORE the sleep, not
            // after the wake-up that may never come. `attemptSleep` below is
            // the single choke point that guarantees it on every sleep path.
            // Best effort, and NOT retried — deliberately (review round 18).
            // The protective action already happened: `disablesleep` is at 0,
            // so the Mac follows its normal power management and sleeps on
            // idle / lid close by itself. This call only accelerates that.
            // Retrying it would mean calling `pmset sleepnow` every 30 s on a
            // machine whose flag is no longer ours — a sleep loop against an
            // operator who is using the Mac, which is worse than the missed
            // acceleration. (Contrast `attemptSleepOnceAfterFailure` below: a
            // FAILED release leaves the flag ON, so there a retry IS the
            // protective act, and it is worth one per episode.)
            attemptSleep(&outcome)
        case .success(let op):
            // Not refused, not verified: treat as a backend failure.
            outcome.mutation = .releaseFailed
            outcome.mutationError = op.error ?? "release not verified (state=\(op.state.rawValue))"
            attemptSleepOnceAfterFailure(&outcome, record: &record, protective: protective)
        case .failure(.backendFailed(let message)):
            // We own the flag and the battery is critical: still try
            // the sleep (best effort, it is not a persistent mutation).
            outcome.mutation = .releaseFailed
            outcome.mutationError = message
            attemptSleepOnceAfterFailure(&outcome, record: &record, protective: protective)
        case .failure(let error):
            // B1/B2/no-op refusal (e.g. ownership changed between the
            // evaluation and the write): no sleep; warn once per episode.
            outcome.mutation = .releaseRefused
            outcome.mutationError = String(describing: error)
            outcome.shouldNotify = !record.latch.warnedCritical
            record.latch.warnedCritical = true
        }
    }

    private func audit(_ outcome: TickOutcome, evaluation: Evaluation, recordBootID: String) {
        auditLog.append(.init(
            ts: ISO8601DateFormatter().string(from: Date()),
            bootID: lidService.bootID,
            reason: evaluation.decision.reason.rawValue,
            outcome: outcome.mutation?.rawValue ?? "none",
            chargePercent: evaluation.input.chargePercent,
            minutesRemaining: evaluation.input.minutesRemaining,
            recordBootID: recordBootID,
            error: outcome.mutationError,
            sleepRC: outcome.sleepRC))
    }

    /// A persistently failing release (e.g. sudoers rule removed) is retried
    /// every tick, but the best-effort sleep + its notification happen once
    /// per discharge episode — never a sleep/notify loop every 30 s.
    ///
    /// `protective` picks WHICH once-per-episode latch applies: the app owns
    /// `failedReleaseSleepTried` (which also gates its notify), while the
    /// backstop owns `protectiveSleepTried` and must not touch the app's
    /// (it shows no notification, so consuming the app's latch would silence a
    /// warning nobody ever saw). It also suppresses the notification for the
    /// protective caller for the same reason (review round 10).
    private mutating func attemptSleepOnceAfterFailure(_ outcome: inout TickOutcome,
                                                      record: inout LowBatteryLatchStore.Record,
                                                      protective: Bool) {
        if protective {
            guard !record.latch.protectiveSleepTried else { return }
        } else {
            guard !record.latch.failedReleaseSleepTried else { return }
            record.latch.failedReleaseSleepTried = true
            outcome.shouldNotify = true
        }
        attemptSleep(&outcome)
        // The protective latch records a sleep the Mac actually TOOK, not one
        // that was merely requested. `pmset sleepnow` can refuse — another
        // process holding the display, a wedged power daemon — and consuming
        // the latch on a failed attempt means the Mac is never asked again for
        // the rest of the discharge episode: exactly the "awake until the
        // battery dies" class this backstop exists to close (review round 17).
        // A failed protective attempt therefore retries next minute; that is a
        // real attempt to protect, not a log loop (the audit line for the
        // repeating release failure is already deduped by key).
        if protective, outcome.sleepRC == 0 {
            record.latch.protectiveSleepTried = true
        }
    }

    /// The ONE sleep call, and therefore the ONE place the lid-close undo is
    /// guaranteed to happen first — on the success path AND on the
    /// best-effort path after a failed release.
    ///
    /// It used to sit only in the successful-release branch, so a failed
    /// release that still slept the Mac went down with apps suspended and
    /// audio muted (caught by ai-review-gate). Putting it here means no caller
    /// can reach `sleepNow` without the undo, whichever branch led there.
    private mutating func attemptSleep(_ outcome: inout TickOutcome) {
        // Carry the undo's attention report into THIS outcome: the Mac may
        // sleep before any other tick can raise it, so discarding it loses the
        // one moment the operator could have been told (gate finding, `Sleep
        // path discards the undo's attention report`).
        if let undo = undoLidCloseBeforeSleep(&outcome), undo.shouldNotify {
            outcome.shouldNotify = true
        }
        let r = sleeper.sleepNow()
        outcome.sleepAttempted = true
        outcome.sleepRC = r.rc
        outcome.sleepOutput = r.output
    }

    /// Undo the lid-close actions before the Mac sleeps (ADR 026).
    ///
    /// The order the plan names is "at the end of a session, BEFORE the release
    /// or the sleep". This is the sleep half: a machine that goes down muted
    /// with Slack frozen comes back in exactly that state, and if the app
    /// never wakes the backstop cannot be relied on to fix it.
    ///
    /// Uses the readings-free `undoAll()`, not `step()`: the conditions are
    /// irrelevant here, the journal is.
    ///
    /// Returns the undo's outcome so `attemptSleep` can carry it, and writes it
    /// into an outcome when one is supplied. It runs on EVERY sleep path, so a
    /// failure branch cannot skip it.
    @discardableResult
    private mutating func undoLidCloseBeforeSleep(
        _ outcome: inout TickOutcome
    ) -> LidCloseActionService.TickOutcome? {
        guard var service = lidCloseActions else { return nil }
        let undo = service.undoAll()
        lidCloseActions = service
        if outcome.lidClose == nil { outcome.lidClose = undo }
        return undo
    }

    /// The no-outcome spelling, for callers that only need the effect.
    @discardableResult
    private mutating func undoLidCloseBeforeSleep() -> LidCloseActionService.TickOutcome? {
        guard var service = lidCloseActions else { return nil }
        let undo = service.undoAll()
        lidCloseActions = service
        return undo
    }
}

extension LowBatteryLatchStore {
    /// Operator lid command outcome hook (popup switch, CLI). Clears a pending
    /// re-arm when the command reached the requested state OR found it already
    /// there (`noChangeRequested`): an explicit OFF on a flag the guard had
    /// already released is still the operator saying "keep it off".
    public func operatorCommandFinished(_ result: Result<OperationResult, LidMutationError>) {
        switch result {
        case .success, .failure(.noChangeRequested):
            clearPendingRearm()
        case .failure:
            break
        }
    }

    /// An explicit operator lid command supersedes a pending guard re-arm:
    /// the human's choice wins, the guard must not flip the flag back later.
    /// Callers run it inside the same `LidWriteLock` section as their write.
    public func clearPendingRearm() {
        var rec = load()
        guard rec.latch.releasedByGuard else { return }
        rec.latch = rec.latch.recordingRearm()
        save(rec)
    }
}
