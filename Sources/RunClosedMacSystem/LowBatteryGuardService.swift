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

    public init(
        lidService: LidMutationService,
        latchStore: LowBatteryLatchStore,
        batteryProvider: @escaping @Sendable () -> BatteryState,
        sleeper: any SystemSleeper,
        lock: LidWriteLock = LidWriteLock(),
        auditLog: LowBatteryAuditLog = LowBatteryAuditLog(),
        sessionService: SessionService? = nil
    ) {
        self.lidService = lidService
        self.latchStore = latchStore
        self.batteryProvider = batteryProvider
        self.sleeper = sleeper
        self.lock = lock
        self.auditLog = auditLog
        self.sessionService = sessionService
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

    private mutating func lockedTick() -> TickOutcome {
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
            // Emergency ownership of OUR stale record is scoped to this one
            // branch; `LidMutationService` re-checks that the record is ours.
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
                // to cancel, and the re-arm below may revive it. A pause that
                // fails to save is restored by the next tick's reconciliation
                // (flag OFF + re-arm debt pending = a battery pause).
                sessionService?.pauseForBattery()
                // Persist the re-arm debt and the audit line BEFORE asking
                // for sleep: the Mac may go down right after `sleepnow`.
                latchStore.save(record)
                audit(outcome, evaluation: evaluation, recordBootID: recordBootIDBefore)
                attemptSleep(&outcome)
            case .success(let op):
                // Not refused, not verified: treat as a backend failure.
                outcome.mutation = .releaseFailed
                outcome.mutationError = op.error ?? "release not verified (state=\(op.state.rawValue))"
                attemptSleepOnceAfterFailure(&outcome, record: &record)
            case .failure(.backendFailed(let message)):
                // We own the flag and the battery is critical: still try
                // the sleep (best effort, it is not a persistent mutation).
                outcome.mutation = .releaseFailed
                outcome.mutationError = message
                attemptSleepOnceAfterFailure(&outcome, record: &record)
            case .failure(let error):
                // B1/B2/no-op refusal (e.g. ownership changed between the
                // evaluation and the write): no sleep; warn once per episode.
                outcome.mutation = .releaseRefused
                outcome.mutationError = String(describing: error)
                outcome.shouldNotify = !record.latch.warnedCritical
                record.latch.warnedCritical = true
            }

        case .rearm:
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
        return outcome
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
    private func attemptSleepOnceAfterFailure(_ outcome: inout TickOutcome,
                                              record: inout LowBatteryLatchStore.Record) {
        guard !record.latch.failedReleaseSleepTried else { return }
        record.latch.failedReleaseSleepTried = true
        outcome.shouldNotify = true
        attemptSleep(&outcome)
    }

    private func attemptSleep(_ outcome: inout TickOutcome) {
        let r = sleeper.sleepNow()
        outcome.sleepAttempted = true
        outcome.sleepRC = r.rc
        outcome.sleepOutput = r.output
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
