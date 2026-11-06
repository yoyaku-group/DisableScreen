import Foundation
import RunClosedCore
import RunClosedPersistence

/// Executes `SessionPolicy` decisions against the real lid flag and the
/// on-disk session record (ADR 023).
///
/// It does NOT take `LidWriteLock` itself. Every caller already runs inside
/// one section — the popup (`tryWithLock`), the CLI (`withLock`), the guard
/// tick (`withLock`) — and `withLock` opens a NEW fd, so nesting it would
/// deadlock the app. Taking the lock here would make every one of those call
/// sites a nested acquisition. The rule is stated on each mutating method.
///
/// The lid backend is injected as closures rather than a stored
/// `LidMutationService`. Ownership lives only on disk (`owned_lid.json`),
/// read and written under the caller's `LidWriteLock`, so the fresh service
/// `live()` builds per call sees exactly what the guard's own service sees.
/// If `LidMutationService` ever caches ownership in memory, this seam must
/// take the caller's instance instead.
public struct SessionService {

    public var store: SessionStore
    public var latchStore: LowBatteryLatchStore
    public var continuous: any ContinuousClock
    /// Injectable wall clock (tests pin it; production is `Date()`).
    public var wallClock: @Sendable () -> Date
    /// Live `pmset -g` readback (`nil` = unknown, B1).
    public var observedFlag: @Sendable () -> Bool?
    /// The ownership record as persisted, plus the current boot.
    public var ownershipRecord: @Sendable () -> (bootID: String, ownedEnabled: Bool)
    /// Apply the lid flag through the gated `LidMutationService`.
    public var applyLid: (Bool, LidMutationService.Initiator) -> Result<OperationResult, LidMutationError>

    public init(
        store: SessionStore,
        latchStore: LowBatteryLatchStore,
        continuous: any ContinuousClock,
        wallClock: @escaping @Sendable () -> Date = { Date() },
        observedFlag: @escaping @Sendable () -> Bool?,
        ownershipRecord: @escaping @Sendable () -> (bootID: String, ownedEnabled: Bool),
        applyLid: @escaping (Bool, LidMutationService.Initiator) -> Result<OperationResult, LidMutationError>
    ) {
        self.store = store
        self.latchStore = latchStore
        self.continuous = continuous
        self.wallClock = wallClock
        self.observedFlag = observedFlag
        self.ownershipRecord = ownershipRecord
        self.applyLid = applyLid
    }

    /// Live wiring against the production pmset backend.
    public static func live(bootID: String) -> SessionService {
        SessionService(
            store: SessionStore(),
            latchStore: LowBatteryLatchStore(),
            continuous: SystemContinuousClock(bootID: bootID),
            observedFlag: { PowerReadback.lidStayAwake() },
            ownershipRecord: {
                let rec = OwnedLidAssertion(currentBootID: bootID).load()
                return (rec.bootID, rec.ownedEnabled)
            },
            applyLid: { enabled, initiator in
                var service = LidMutationService(
                    bootID: bootID,
                    mutator: LidAssertions.live(),
                    store: OwnedLidAssertion(currentBootID: bootID),
                    priorProvider: { PowerReadback.lidStayAwake() })
                return service.setEnabled(enabled, initiator: initiator)
            })
    }

    // MARK: — Read

    public func currentNow() -> SessionPolicy.Now {
        SessionPolicy.Now(wall: wallClock(),
                          continuousNanoseconds: continuous.nowContinuousNanoseconds,
                          bootID: continuous.bootID)
    }

    public func load() -> KeepAwakeSession? { store.load() }

    public var currentOwnership: LowBatteryPolicy.LidOwnership {
        let rec = ownershipRecord()
        return LowBatteryPolicy.LidOwnership.classify(
            recordBootID: rec.bootID,
            recordOwnedEnabled: rec.ownedEnabled,
            currentBootID: continuous.bootID)
    }

    // MARK: — Start (caller holds LidWriteLock)

    public enum StartOutcome: Equatable, Sendable {
        case started(KeepAwakeSession)
        /// The flag was already ON and owned on this boot: the existing
        /// indefinite session (the plain switch) simply became timed. No
        /// second write was issued.
        case adoptedRunningFlag(KeepAwakeSession)
    }

    /// Start a session. `duration == nil` = indefinite (the plain switch).
    ///
    /// JOURNAL BEFORE CHANGE: the record is written BEFORE the flag is set, so
    /// a crash in between leaves a deadline the next launch can reconcile. If
    /// setting the flag then fails, the record is deleted — a session that is
    /// not backing a flag must not exist.
    public mutating func start(for duration: TimeInterval?) -> Result<StartOutcome, SessionError> {
        let now = currentNow()
        let existing = store.load()
        let flag = observedFlag()
        let decision = SessionPolicy.start(
            duration: duration,
            now: now,
            observedFlag: flag,
            ownership: currentOwnership,
            existing: existing)
        let session: KeepAwakeSession
        switch decision {
        case .failure(let refusal):
            switch refusal {
            case .alreadyRunning: return .failure(.alreadyRunning)
            case .nonPositiveDuration: return .failure(.nonPositiveDuration)
            case .flagOnNotOwned: return .failure(.flagOnNotOwned)
            case .durationTooLong: return .failure(.durationTooLong)
            }
        case .success(let s):
            session = s
        }

        // Journal before change: no record on disk, no flag write.
        guard store.save(session) else {
            return .failure(.backendFailed("session record could not be written"))
        }
        let result = applyLid(true, .operatorCommand)
        switch result {
        case .success(let op) where op.state == .verified:
            // An explicit start supersedes a pending low-battery re-arm, on
            // every surface (popup and CLI alike).
            latchStore.clearPendingRearm()
            return .success(.started(session))
        case .failure(.noChangeRequested(target: true)):
            // The flag was already ON: owned for a timed start (the policy
            // refuses a foreign flag), possibly foreign for an indefinite
            // one, which `end()` then releases as an operator command.
            latchStore.clearPendingRearm()
            return .success(.adoptedRunningFlag(session))
        case .success(let op):
            restore(existing)
            return .failure(.backendFailed(op.error ?? "not verified (state=\(op.state.rawValue))"))
        case .failure(let error):
            restore(existing)
            return .failure(Self.map(error))
        }
    }

    /// A failed start puts back the record it replaced (a due session the
    /// next tick still has to end), or removes its own record.
    private func restore(_ previous: KeepAwakeSession?) {
        if let previous { store.save(previous) } else { store.clear() }
    }

    // MARK: — Extend / end (caller holds LidWriteLock)

    /// Push the deadline out by `seconds` from now. Mutates the record only,
    /// never `pmset`: a battery-paused session stays paused until the guard
    /// re-arms the flag.
    public mutating func extend(by seconds: TimeInterval = SessionDuration.extendStep)
        -> Result<KeepAwakeSession, SessionError> {
        guard let session = store.load() else { return .failure(.noSession) }
        guard !session.isIndefinite else { return .failure(.indefiniteSession) }
        guard seconds.isFinite, seconds > 0 else { return .failure(.nonPositiveDuration) }
        // Same cap as `start`: an extension is a bounded push, never a way to
        // reach an unrepresentable deadline.
        guard seconds <= SessionDuration.maximum else { return .failure(.durationTooLong) }
        let next = SessionPolicy.extend(session, by: seconds, now: currentNow())
        guard store.save(next) else {
            return .failure(.backendFailed("session record could not be written"))
        }
        return .success(next)
    }

    /// Operator pressed End (or ran `session end`).
    ///
    /// A TIMED session ends through the same ownership gate as expiry, so End
    /// never turns off a flag another tool owns (a timed start refuses a
    /// foreign flag in the first place). An INDEFINITE session is the plain
    /// switch, which may have adopted a flag another tool set: End is then the
    /// switch OFF, an operator command (ADR 021). Otherwise the record would
    /// go while the Mac stays awake with no deadline.
    public mutating func end() -> Result<SessionEndOutcome, SessionError> {
        guard let session = store.load() else { return .failure(.noSession) }
        let initiator: LidMutationService.Initiator = session.isIndefinite
            ? .operatorCommand
            : Self.releaseInitiator(for: session, currentBootID: continuous.bootID)
        return .success(release(session, initiator: initiator, clearingRecord: true))
    }

    // MARK: — Expiry (caller holds LidWriteLock — called from the guard tick)

    public enum ExpiryOutcome: Equatable, Sendable {
        case noSession
        case notDue
        case ended(SessionEndOutcome)
        /// The record stays for the next tick. Retrying is correct: a failed
        /// release must never look like a finished session.
        case retained(String)
    }

    /// End the session if a deadline has passed.
    ///
    /// Normal end order (ADR 023 §5): release through the ownership gate →
    /// clear the record when the result is VERIFIED, or `notOwned` (the flag is
    /// already OFF or belongs to someone else — nothing left to protect).
    public mutating func expireIfDue() -> ExpiryOutcome {
        guard let session = store.load() else { return .noSession }
        let now = currentNow()
        guard SessionPolicy.dueReason(session, now: now) != nil else { return .notDue }
        let outcome = release(
            session,
            initiator: Self.releaseInitiator(for: session, currentBootID: continuous.bootID),
            clearingRecord: true)
        switch outcome {
        case .released, .flagNotOwned, .flagAlreadyOff:
            return .ended(outcome)
        case .releaseFailed(let message):
            return .retained(message)
        }
    }

    // MARK: — Low-battery interplay (ADR 023 §4)

    /// The guard released the flag on a critical battery. The session is
    /// PAUSED, never ended: the operator's deadline is not the battery's to
    /// cancel, and the re-arm path below may revive it.
    @discardableResult
    public mutating func pauseForBattery() -> Bool {
        guard var session = store.load(), !session.isPaused else { return false }
        session = SessionPolicy.pause(session, reason: .lowBattery)
        store.save(session)
        return true
    }

    /// The guard re-armed the flag and the session is still valid: clear the
    /// pause so the countdown resumes against its original deadline.
    @discardableResult
    public mutating func resumeAfterRearm() -> Bool {
        guard var session = store.load(), session.isPaused else { return false }
        session = SessionPolicy.resume(session)
        store.save(session)
        return true
    }

    /// The flag reads ON and ours again while the session is paused: it came
    /// back another way (the switch, `lid-stay-awake on`, a re-arm that found
    /// it already on). Resume the countdown, as long as the guard itself could
    /// have re-armed this session; otherwise "Paused" would stay on screen
    /// while the Mac is awake.
    @discardableResult
    public mutating func resumeIfFlagIsBack() -> Bool {
        guard allowsRearm() else { return false }
        return resumeAfterRearm()
    }

    /// May the guard re-arm the flag? Only while a session is still live and
    /// belongs to this boot. `true` when there is no session at all — that is
    /// ADR 022's behaviour, untouched.
    public func allowsRearm() -> Bool {
        guard let session = store.load() else { return true }
        return SessionPolicy.allowsRearm(session, now: currentNow())
    }

    // MARK: — Release plumbing

    /// The initiator a release runs under.
    ///
    /// Same boot → `.automatic`, the unchanged B2 path (ADR 023 §5, "release
    /// `.automatic`"). Previous boot → `.sessionRecovery(session.bootID)`,
    /// which admits OUR OWN record from exactly the boot that started the
    /// session and nothing else (ADR 023 §3: leaving the global flag on after
    /// the deadline is the strictly worse outcome).
    public static func releaseInitiator(
        for session: KeepAwakeSession,
        currentBootID: String
    ) -> LidMutationService.Initiator {
        session.isOnBoot(currentBootID)
            ? .automatic
            : .sessionRecovery(bootID: session.bootID)
    }

    /// Release the flag for `session` as `initiator`.
    private mutating func release(_ session: KeepAwakeSession,
                                  initiator: LidMutationService.Initiator,
                                  clearingRecord: Bool) -> SessionEndOutcome {
        let result = applyLid(false, initiator)
        switch result {
        case .success(let op) where op.state == .verified:
            finish(clearingRecord: clearingRecord)
            return .released
        case .failure(.notOwned):
            // The flag is OFF already or belongs to another tool: the session
            // has nothing left to protect. No mutation happened.
            finish(clearingRecord: clearingRecord)
            return .flagNotOwned
        case .failure(.noChangeRequested(target: false)):
            finish(clearingRecord: clearingRecord)
            return .flagAlreadyOff
        case .success(let op):
            return .releaseFailed(op.error ?? "not verified (state=\(op.state.rawValue))")
        case .failure(let error):
            return .releaseFailed(Self.describe(error))
        }
    }

    /// The ONE end-of-session path. Every way a session can finish — expiry,
    /// the End button, and the quit teardown — goes through here, so they
    /// cannot drift apart.
    ///
    /// A finished session clears its record AND any pending low-battery
    /// re-arm. The latch matters as much as the record: a session paused by
    /// the guard leaves `releasedByGuard` set, and without this clear the next
    /// launch on AC would re-arm the flag for a session that no longer exists
    /// (ADR 023 §4).
    ///
    /// Callers run it inside `LidWriteLock`; it takes no lock itself.
    public func finishSession() {
        store.clear()
        latchStore.clearPendingRearm()
    }

    /// Quit teardown (ADR 023 §5): the session ends with the flag it backed.
    /// It runs only when a session is on disk AND the flag reads off after the
    /// restore.
    ///
    /// An INDEFINITE session is the plain switch, which ADR 022 governs: quit
    /// clears its record only, so a pending re-arm owed to the switch survives
    /// the quit exactly as it did before sessions existed. A TIMED session (or
    /// an unreadable record) ends through `finishSession()`, which also voids
    /// its re-arm debt.
    ///
    /// Callers run it inside `LidWriteLock`; it takes no lock itself.
    public func finishOnQuit(flagReadsOff: Bool) {
        guard store.exists, flagReadsOff else { return }
        if let session = store.load(), session.isIndefinite {
            store.clear()
        } else {
            finishSession()
        }
    }

    /// Seam for the release path: it decides whether the record survives (a
    /// failed release keeps it for the next tick), so it needs the switch.
    private func finish(clearingRecord: Bool) {
        guard clearingRecord else { return }
        finishSession()
    }

    private static func map(_ error: LidMutationError) -> SessionError {
        switch error {
        case .preconditionUnknown: return .preconditionUnknown
        case .notOwned: return .notOwned
        case .noChangeRequested(let target):
            return target ? .alreadyRunning : .flagAlreadyOff
        case .backendFailed(let message): return .backendFailed(message)
        }
    }

    private static func describe(_ error: LidMutationError) -> String {
        switch error {
        case .preconditionUnknown: return "observed prior state is UNKNOWN (B1)"
        case .notOwned: return "not owned on this boot (B2)"
        case .noChangeRequested(let target): return "no change requested (target=\(target))"
        case .backendFailed(let message): return message
        }
    }
}

/// Terminal outcome of a release attempt.
public enum SessionEndOutcome: Equatable, Sendable {
    /// `disablesleep 0` verified by readback.
    case released
    /// Refused `notOwned`: the flag is already OFF or set by another tool.
    /// Nothing was mutated.
    case flagNotOwned
    /// The flag already read OFF (no-op refusal).
    case flagAlreadyOff
    /// The write or its readback failed; the record is kept for a retry.
    case releaseFailed(String)

    public var isFailure: Bool {
        if case .releaseFailed = self { return true }
        return false
    }

    public var rawValue: String {
        switch self {
        case .released: return "released"
        case .flagNotOwned: return "flagNotOwned"
        case .flagAlreadyOff: return "flagAlreadyOff"
        case .releaseFailed: return "releaseFailed"
        }
    }

    public var failureMessage: String? {
        if case .releaseFailed(let message) = self { return message }
        return nil
    }
}

/// Typed failures shared by the popup, the CLI and the guard tick.
public enum SessionError: Error, Equatable, Sendable {
    case noSession
    case alreadyRunning
    case nonPositiveDuration
    /// "+30 min" on an indefinite (plain switch) session has no deadline to
    /// push; the operator picks a duration instead.
    case indefiniteSession
    /// Starting a timed session on a flag we do not own would succeed now and
    /// fail `notOwned` at expiry — refuse up front (ADR 023 §1).
    case flagOnNotOwned
    /// Past `SessionDuration.maximum` (7 days) — a usage error.
    case durationTooLong
    case preconditionUnknown
    case notOwned
    /// The flag already read OFF when a release was requested — no write needed.
    case flagAlreadyOff
    case backendFailed(String)
}
