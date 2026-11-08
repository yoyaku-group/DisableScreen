import Foundation
import RunClosedCore
import RunClosedPersistence

/// Kill switch (rules/49): `defaults write com.benjaminbelaga.RunClosed
/// thermalGuardEnabled -bool false` disables the thermal guard without a
/// rebuild; absent key = enabled.
///
/// Read at the same place as `LowBatteryGuardSettings.isEnabled()`, and for the
/// same reason: an operator who says no must not be overruled by a background
/// tick. One difference, and it is deliberate — this switch is read once per
/// tick by BOTH the app and the backstop, so turning it off stops the release
/// on both.
public enum ThermalGuardSettings {
    public static let suiteName = "com.benjaminbelaga.RunClosed"
    public static let enabledKey = "thermalGuardEnabled"

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

/// Executes `ThermalPolicy` decisions (ADR 025).
///
///   evaluate : thermal state + clamshell + display attachment + `pmset -g`
///              flag + ownership record → policy
///   tick     : evaluate → act → persist the latch from the OUTCOME
///     releaseAndSleep : `LidMutationService.setEnabled(false, .automatic)`
///                       (B1 + B2 ownership gate unchanged) → verified →
///                       latch `releasedForHeat` → audit → `pmset sleepnow`
///     warn            : nothing here — the caller notifies the operator
///
/// Heat ENDS the session rather than pausing it: a machine that overheated must
/// not be woken by the battery guard's re-arm on AC, which is what a pause
/// would allow (ADR 025).
///
/// UI-free and unit-testable with fakes (lid assertion, sleeper, readings).
public struct ThermalGuardService {

    public var lidService: LidMutationService
    public let latchStore: ThermalLatchStore
    public let thermalProvider: @Sendable () -> ThermalState
    public let lidClosedProvider: @Sendable () -> Bool?
    public let externalDisplayProvider: @Sendable () -> Bool?
    /// Monotonic seconds that survive a process restart (production:
    /// `ProcessInfo.systemUptime` via `MonotonicReadback`). Injected so a test
    /// can walk ten minutes in two calls.
    public let monotonic: @Sendable () -> Double
    public var sleeper: any SystemSleeper
    /// The audit trail of the guard's actions (ADR 025).
    public let auditLog: ThermalAuditLog
    /// ADR 023 session layer. A thermal release ENDS the session; `nil` means
    /// there is none, and the release is the same either way.
    public var sessionService: SessionService?
    /// ADR 026 lid-close actions. A thermal release must UNDO them before the
    /// Mac sleeps: otherwise it goes down muted with an app frozen and comes
    /// back that way, with nobody left to notice. `nil` = no lid-close layer.
    public var lidCloseActions: LidCloseActionService?

    public init(
        lidService: LidMutationService,
        latchStore: ThermalLatchStore,
        thermalProvider: @escaping @Sendable () -> ThermalState,
        lidClosedProvider: @escaping @Sendable () -> Bool?,
        externalDisplayProvider: @escaping @Sendable () -> Bool?,
        monotonic: @escaping @Sendable () -> Double,
        sleeper: any SystemSleeper,
        auditLog: ThermalAuditLog = ThermalAuditLog(),
        sessionService: SessionService? = nil,
        lidCloseActions: LidCloseActionService? = nil
    ) {
        self.lidService = lidService
        self.latchStore = latchStore
        self.thermalProvider = thermalProvider
        self.lidClosedProvider = lidClosedProvider
        self.externalDisplayProvider = externalDisplayProvider
        self.monotonic = monotonic
        self.sleeper = sleeper
        self.auditLog = auditLog
        self.sessionService = sessionService
        self.lidCloseActions = lidCloseActions
    }

    /// Live wiring: real thermal state, real clamshell bit, real display
    /// inventory, real `pmset`, real session layer.
    public static func live(bootID: String,
                            sessionService: SessionService?,
                            lidCloseActions: LidCloseActionService? = nil) -> ThermalGuardService {
        let lidStore = OwnedLidAssertion(currentBootID: bootID)
        return ThermalGuardService(
            lidService: LidMutationService(
                bootID: bootID,
                mutator: LidAssertions.live(),
                store: lidStore,
                priorProvider: { PowerReadback.lidStayAwake() }),
            latchStore: ThermalLatchStore(),
            thermalProvider: { ThermalReadback.read() },
            lidClosedProvider: { ClamshellReadback.lidClosed() },
            externalDisplayProvider: { ClamshellReadback.externalDisplayConnected() },
            monotonic: { MonotonicReadback.seconds() },
            sleeper: PMSetSleeper(),
            sessionService: sessionService,
            lidCloseActions: lidCloseActions)
    }

    public struct Evaluation: Equatable, Sendable {
        public var input: ThermalPolicy.Input
        public var decision: ThermalPolicy.Decision
        public var latchBefore: ThermalPolicy.Latch
        public var latchAfter: ThermalPolicy.Latch
    }

    public enum MutationOutcome: String, Codable, Sendable, Equatable {
        /// `disablesleep 0` verified by readback.
        case released
        /// Refused before any write (B1 unknown prior, B2 not owned, no-op).
        case releaseRefused
        /// The write or its readback failed.
        case releaseFailed
    }

    public struct TickOutcome: Equatable, Sendable {
        public var evaluation: Evaluation
        public var mutation: MutationOutcome?
        public var mutationError: String?
        public var sleepAttempted = false
        public var sleepRC: Int32?
        public var sleepOutput: String?
        /// Whether the caller should notify about this tick. Failures and
        /// warnings notify once per episode, never every 30 s.
        public var shouldNotify: Bool = false
        /// The operator-facing text to notify about, when `shouldNotify`.
        public var notice: Notice?
        /// The session was ended by the thermal release (ADR 025: heat ENDS a
        /// session, it does not pause it).
        public var sessionEndedByHeat: Bool = false
        /// What the lid-close undo did before this release's sleep (ADR 026).
        /// `nil` when no lid-close layer is wired or nothing was applied.
        public var lidCloseUndo: LidCloseActionService.TickOutcome?
        /// The latch could not be persisted this tick.
        ///
        /// Reported rather than swallowed because of what it costs: the
        /// sustained-heat clock (`seriousSince`) lives in that file, so a latch
        /// that never lands restarts the ten-minute grace period on every tick
        /// and the `.seriousSustained` release NEVER fires. The guard looks
        /// healthy and is silently inert. Callers surface it (stderr here, the
        /// popup/backstop report elsewhere) exactly as the ADR 024 backstop
        /// surfaces a heartbeat it could not write.
        public var latchSaveFailed: Bool = false
    }

    /// Which notification the caller should show. Resolved here, rendered by
    /// the UI layer through `L10n`, so the service stays AppKit-free and the
    /// tests can assert on a case instead of a sentence.
    public enum Notice: String, Sendable, Equatable {
        /// `critical`, released, Mac going to sleep.
        case releasedCritical
        /// `serious` sustained, released, Mac going to sleep.
        case releasedSustained
        /// The flag is ours and the write did not take: the Mac is still kept
        /// awake while it overheats.
        case releaseFailed
        /// Refused before any write — the flag is not provably ours (B2) or
        /// could not be read (B1): the guard cannot protect the machine.
        case releaseRefused
        /// `serious`, enclosed and ours: the heads-up before the grace period
        /// runs out.
        case seriousHeadsUp
        /// `serious`, enclosed, but the flag is not ours.
        case seriousNotProtected
    }

    /// Read-only evaluation: no mutation, no persistence write. Used by
    /// `runclosed thermal status` and as the first half of `tick()`.
    public func evaluate() -> Evaluation {
        let input = ThermalPolicy.Input(
            state: thermalProvider(),
            lidClosed: lidClosedProvider(),
            externalDisplayConnected: externalDisplayProvider(),
            lidFlag: lidService.priorProvider(),
            ownership: ownership(),
            monotonic: monotonic(),
            bootID: lidService.bootID)
        let latch = latchStore.load().latch
        let (decision, next) = ThermalPolicy.step(input, latch: latch)
        return Evaluation(input: input, decision: decision, latchBefore: latch, latchAfter: next)
    }

    /// The ownership classification of `owned_lid.json` against this boot.
    /// Shared by the app tick and the backstop so the two cannot disagree on
    /// what "ours" means.
    public func ownership() -> LowBatteryPolicy.LidOwnership {
        let rec = lidService.store.load()
        return LowBatteryPolicy.LidOwnership.classify(
            recordBootID: rec.bootID,
            recordOwnedEnabled: rec.ownedEnabled,
            currentBootID: lidService.bootID)
    }

    /// One thermal step. Takes NO lock: every caller already runs inside one
    /// `LidWriteLock` section (the app's shared guard tick, the backstop's one
    /// section), and `withLock` opens a new fd — nesting it would deadlock.
    @discardableResult
    public mutating func step() -> TickOutcome {
        let evaluation = evaluate()
        var record = latchStore.load()
        let before = record
        record.latch = evaluation.latchAfter
        var outcome = TickOutcome(evaluation: evaluation)

        switch evaluation.decision.action {
        case .none:
            break

        case .warn:
            // A warn mutates nothing but it IS an action — the operator is
            // told — so it earns one line, once per episode. The policy has
            // already decided whether THIS tick is the one that speaks (the
            // latch bits), so a condition that holds for an hour produces one
            // line, not 120.
            outcome.shouldNotify = true
            outcome.notice = Self.notice(for: evaluation.decision)
            audit(outcome, evaluation: evaluation, recordBootID: lidService.store.load().bootID)

        case .releaseAndSleep:
            performRelease(evaluation: evaluation, record: &record, outcome: &outcome)
        }

        if record != before {
            persistLatch(record, into: &outcome)
        }
        return outcome
    }

    /// Persist the latch, and make a failure VISIBLE.
    ///
    /// The stderr line is the safety net, not the notification: the guard's own
    /// audit trail records what it did, while this records that its memory is
    /// broken — the one failure mode that makes an untouched machine look
    /// protected while it is not. `TickOutcome.latchSaveFailed` carries the same
    /// fact to the callers that can do something with it.
    private func persistLatch(_ record: ThermalLatchStore.Record,
                              into outcome: inout TickOutcome) {
        guard !latchStore.save(record) else { return }
        outcome.latchSaveFailed = true
        FileHandle.standardError.write(Data(
            ("[RunClosed] thermal: latch could NOT be written to \(latchStore.url.path) "
             + "— the sustained-heat clock will restart every tick, so the "
             + "ten-minute release cannot fire until this is fixed\n").utf8))
    }

    /// The ONE thermal release branch — shared by the app's guard tick and the
    /// ADR 024 backstop, so the two cannot drift apart: journal-with-outcome,
    /// end the session, persist the latch, audit before the sleep, then
    /// `pmset sleepnow`.
    private mutating func performRelease(evaluation: Evaluation,
                                        record: inout ThermalLatchStore.Record,
                                        outcome: inout TickOutcome) {
        let recordBootID = lidService.store.load().bootID
        // ADR 026: undo the lid-close effects BEFORE releasing the flag.
        //
        // `setEnabled(false)` re-enables normal sleep, and with the lid closed
        // the Mac can suspend before this function's later lines ever run —
        // leaving the sound muted and apps paused across the sleep (gate
        // finding, `Thermal undo runs after releasing lid protection`).
        if var actions = lidCloseActions {
            outcome.lidCloseUndo = actions.undoAll()
            lidCloseActions = actions
        }
        // `.automatic` only: heat has no cross-boot widening. A stale record is
        // NOT active ownership, and the policy already refused that case — if
        // it ever got here, the gate refuses too (B2 stays authoritative).
        let result = lidService.setEnabled(false, initiator: .automatic)
        switch result {
        case .success(let op) where op.state == .verified:
            outcome.mutation = .released
            outcome.shouldNotify = true
            outcome.notice = evaluation.decision.reason == .criticalOwned
                ? .releasedCritical : .releasedSustained
            record.latch = record.latch.recordingRelease()
            // Heat ENDS the session (ADR 025). Unlike the battery pause, there
            // is no re-arm that may revive it: a machine that overheated must
            // not be woken again by the guard. `finishSession()` also voids the
            // pending battery re-arm, so nothing resurrects the flag on AC.
            if let session = sessionService, session.load() != nil {
                session.finishSession()
                outcome.sessionEndedByHeat = true
            }
            // Persist the latch BEFORE asking for sleep: the Mac may go down
            // right after `sleepnow`, and a latch written afterwards would be
            // lost with it (journal before change, ADR 009/022).
            persistLatch(record, into: &outcome)
            // Best effort, and NOT retried: the protective action already
            // happened, so the Mac follows its normal power management and
            // sleeps/throttles on its own. Retrying would mean calling
            // `pmset sleepnow` every 30 s against an operator who may have
            // plugged a display in — worse than a missed acceleration.
            attemptSleep(&outcome)
            // Audit AFTER the sleep attempt, not before: the line carries
            // `sleepRC`, and a post-mortem of an overheat has to be able to say
            // whether the Mac actually slept or merely had the flag released.
            // The latch is persisted above for the opposite reason — it is
            // state, this is the record of what happened.
            audit(outcome, evaluation: evaluation, recordBootID: recordBootID)
        case .success(let op):
            outcome.mutation = .releaseFailed
            outcome.mutationError = op.error ?? "release not verified (state=\(op.state.rawValue))"
            reportRepeatingFailure(evaluation: evaluation, record: &record, outcome: &outcome,
                                   recordBootID: recordBootID)
        case .failure(.backendFailed(let message)):
            outcome.mutation = .releaseFailed
            outcome.mutationError = message
            reportRepeatingFailure(evaluation: evaluation, record: &record, outcome: &outcome,
                                   recordBootID: recordBootID)
        case .failure(let error):
            // B1/B2/no-op refusal: no write, no sleep. The operator is told
            // once per episode, tracked by the latch bit — NOT by the audit
            // line, because `criticalOwned` retries on every tick and the
            // condition genuinely repeats.
            outcome.mutation = .releaseRefused
            outcome.mutationError = String(describing: error)
            outcome.notice = .releaseRefused
            if evaluation.decision.reason == .criticalOwned {
                outcome.shouldNotify = !evaluation.latchBefore.warnedCritical
                record.latch.warnedCritical = true
            } else {
                outcome.shouldNotify = !evaluation.latchBefore.warnedSerious
                record.latch.warnedSerious = true
            }
            // A line only when the episode is NEW: otherwise a refused release
            // holding the same condition would write 2 880 identical lines a
            // day, the flood the "one line per action" rule exists to prevent.
            if outcome.shouldNotify {
                audit(outcome, evaluation: evaluation, recordBootID: recordBootID)
            }
        }
    }

    /// A failed release is reported once per (reason, error) episode.
    ///
    /// A permanently broken rail — a revoked sudoers rule — holds the identical
    /// failure on every tick. Retrying the release is correct (the next tick may
    /// succeed); saying so 2 880 times a day is the flood "one line per action"
    /// forbids. A DIFFERENT error is a different episode and always speaks, so a
    /// changed failure is never hidden behind the old one (the same rule the
    /// ADR 024 backstop applies to `sessionExpiryRetained`).
    private func reportRepeatingFailure(evaluation: Evaluation,
                                        record: inout ThermalLatchStore.Record,
                                        outcome: inout TickOutcome,
                                        recordBootID: String) {
        let key = "\(evaluation.decision.reason.rawValue):\(outcome.mutationError ?? "-")"
        outcome.notice = .releaseFailed
        guard evaluation.latchBefore.reportedFailure != key else {
            outcome.shouldNotify = false
            return
        }
        outcome.shouldNotify = true
        record.latch.reportedFailure = key
        audit(outcome, evaluation: evaluation, recordBootID: recordBootID)
    }

    /// Which words the operator gets for a `.warn` decision.
    ///
    /// The once-per-episode dedupe already happened in the policy (that is what
    /// its `.warn`/`.none` answer means), so this maps only the REASON:
    ///
    /// - `seriousWarn` — enclosed and ours: the heads-up before the grace
    ///   period runs out. Silent when the flag is not read (the policy's own
    ///   `seriousWarn` never reaches here in that case).
    /// - `notOwned` / `lidFlagUnknown` — the guard cannot protect the machine,
    ///   at either severity. That is the one case where `serious` must speak:
    ///   the operator has to give RunClosed the flag for the rule to apply.
    ///
    /// `lidOpen` and `externalDisplay` deliberately map to nothing: those are
    /// the ordinary shape of heavy work, and alerting on them would train the
    /// operator to ignore the alert that matters.
    static func notice(for decision: ThermalPolicy.Decision) -> Notice? {
        guard decision.action == .warn else { return nil }
        switch decision.reason {
        case .seriousWarn:
            return decision.state.isCritical ? .releaseRefused : .seriousHeadsUp
        case .notOwned, .lidFlagUnknown:
            return decision.state.isCritical ? .releaseRefused : .seriousNotProtected
        case .lidOpen, .lidUnknown, .externalDisplay:
            return decision.state.isCritical ? .releaseRefused : nil
        case .nominal, .fair, .lidFlagOff, .seriousSustained, .criticalOwned:
            return nil
        }
    }

    private func attemptSleep(_ outcome: inout TickOutcome) {
        let r = sleeper.sleepNow()
        outcome.sleepAttempted = true
        outcome.sleepRC = r.rc
        outcome.sleepOutput = r.output
    }

    private func audit(_ outcome: TickOutcome, evaluation: Evaluation, recordBootID: String) {
        auditLog.append(.init(
            ts: ISO8601DateFormatter().string(from: Date()),
            bootID: lidService.bootID,
            reason: evaluation.decision.reason.rawValue,
            outcome: outcome.mutation?.rawValue ?? "none",
            thermalState: evaluation.input.state.rawValue,
            lid: Self.triState(evaluation.input.lidClosed, closed: "closed", open: "open"),
            externalDisplay: Self.triState(
                evaluation.input.externalDisplayConnected, closed: "connected", open: "none"),
            ownership: evaluation.input.ownership.rawValue,
            recordBootID: recordBootID,
            error: outcome.mutationError,
            sleepRC: outcome.sleepRC))
    }

    private static func triState(_ value: Bool?, closed: String, open: String) -> String {
        guard let value else { return "unknown" }
        return value ? closed : open
    }
}

/// Monotonic seconds for the thermal grace period.
///
/// `systemUptime` is the right clock here and the WRONG one for ADR 023: a
/// session deadline must survive sleep and so uses `mach_continuous_time`, but
/// a thermal episode cannot span a sleep meaningfully — a machine that slept
/// cooled down, and the state is re-read on wake. `systemUptime` is monotonic
/// and needs no timebase conversion; a restart resets the latch through
/// `seriousSinceBootID`, so the counter restarting at boot costs nothing.
public enum MonotonicReadback {
    public static func seconds() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}
