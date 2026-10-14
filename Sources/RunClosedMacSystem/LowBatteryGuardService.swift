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

    public init(
        lidService: LidMutationService,
        latchStore: LowBatteryLatchStore,
        batteryProvider: @escaping @Sendable () -> BatteryState,
        sleeper: any SystemSleeper,
        lock: LidWriteLock = LidWriteLock(),
        auditLog: LowBatteryAuditLog = LowBatteryAuditLog()
    ) {
        self.lidService = lidService
        self.latchStore = latchStore
        self.batteryProvider = batteryProvider
        self.sleeper = sleeper
        self.lock = lock
        self.auditLog = auditLog
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
        let evaluation = evaluate()
        // Which boot wrote the ownership record, captured before any write
        // (an emergency release replaces a stale record with this boot's).
        let recordBootIDBefore = lidService.store.load().bootID
        var outcome = TickOutcome(evaluation: evaluation)
        var record = latchStore.load()
        let before = record
        record.latch = evaluation.latchAfter

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
            let result = lidService.setEnabled(true, initiator: .automatic)
            switch result {
            case .success(let op) where op.state == .verified:
                outcome.mutation = .rearmed
                outcome.shouldNotify = true
                record.latch = record.latch.recordingRearm()
            case .failure(.noChangeRequested(target: true)):
                outcome.mutation = .rearmAlreadyOn
                record.latch = record.latch.recordingRearm()
            case .success(let op):
                outcome.mutation = .rearmFailed
                outcome.mutationError = op.error ?? "rearm not verified (state=\(op.state.rawValue))"
            case .failure(let error):
                // Keep the latch: retried on the next tick (B3).
                outcome.mutation = .rearmFailed
                outcome.mutationError = String(describing: error)
            }
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
