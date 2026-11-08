import Foundation
import RunClosedCore
import RunClosedPersistence

/// Executes `LidCloseActionPolicy` decisions (ADR 026).
///
///   evaluate : session + clamshell + display + settings + journal → policy
///   step     : evaluate → apply or undo → persist the journal from the
///              OUTCOME, never from the intent (B3)
///
/// The journal discipline is the whole safety story:
///
/// - an effect is written to `lid_close_actions.json` **BEFORE** it is applied,
///   so a crash in the window leaves a record of what to undo;
/// - the journal is cleared only after the undo has been **verified by
///   readback** (ADR 009) — an entry is never deleted on the strength of a
///   successful API return;
/// - the undo runs in the REVERSE order of the apply: apps (`SIGCONT`) then
///   sound. Screen and keyboard are not part of this lot (see ADR 026).
///
/// Takes NO lock: every caller already holds `LidWriteLock` (the app's shared
/// guard tick, the backstop's one section), and `withLock` opens a new fd, so
/// nesting would deadlock. Same contract as `ThermalGuardService.step()`.
public struct LidCloseActionService {

    public let journal: LidCloseActionJournal
    public let auditLog: LidCloseActionAuditLog
    public let audio: any AudioOutputBackend
    public let processes: any ProcessPauseBackend
    public let bootID: String
    /// Injected so the tests pin the timestamp; production is `Date()`.
    public let wallClock: @Sendable () -> Date
    /// The session the actions belong to. Diagnostic only: it is written to the
    /// journal so a later reading can tell which deadline the episode served.
    public var currentSessionIdentity: UUID?

    public init(journal: LidCloseActionJournal,
                auditLog: LidCloseActionAuditLog = LidCloseActionAuditLog(),
                audio: any AudioOutputBackend,
                processes: any ProcessPauseBackend,
                bootID: String,
                wallClock: @escaping @Sendable () -> Date = { Date() }) {
        self.journal = journal
        self.auditLog = auditLog
        self.audio = audio
        self.processes = processes
        self.bootID = bootID
        self.wallClock = wallClock
    }

    /// Live wiring against CoreAudio and libproc.
    public static func live(bootID: String) -> LidCloseActionService {
        LidCloseActionService(
            journal: LidCloseActionJournal(),
            auditLog: LidCloseActionAuditLog(),
            audio: CoreAudioOutputBackend(),
            processes: LibprocPauseBackend(bootID: bootID),
            bootID: bootID)
    }

    // MARK: — Outcomes

    public struct Evaluation: Equatable, Sendable {
        public var input: LidCloseActionPolicy.Input
        public var decision: LidCloseActionPolicy.Decision
        /// The journal as read before the step — what "currently applied" means.
        public var journalBefore: LidCloseActionJournal.Record
    }

    /// What an `.apply` produced. Named for what actually LANDED, not for what
    /// was asked: a partial result reported as `applied` is the lie this enum
    /// exists to prevent.
    public enum ApplyOutcome: String, Codable, Sendable, Equatable {
        /// Every effect asked for is applied and readback-confirmed.
        case applied
        /// Something landed, something did not.
        case partial
        /// Nothing landed.
        case failed
        /// Nothing was asked for (both effect switches off under an enabled
        /// master switch), so there was nothing to do.
        case nothingRequested
    }

    /// What an `.undo` produced.
    public enum UndoOutcome: String, Codable, Sendable, Equatable {
        /// Nothing was applied: a no-op, never an error (idempotence).
        case nothingToDo
        /// Everything came back, readback-confirmed. Journal cleared.
        case restored
        /// A process could not be re-proved and was left stopped on purpose
        /// (ADR 026). The journal keeps it; the operator is told.
        case unverifiedProcesses
        /// The undo ran but a readback did not confirm the restore. The journal
        /// stays so the next step retries.
        case incomplete
    }

    public struct TickOutcome: Equatable, Sendable {
        public var evaluation: Evaluation
        /// What an `.apply` produced. `nil` unless the policy said `.apply`.
        public var apply: ApplyOutcome?
        /// What an `.undo` produced. `nil` unless the policy said `.undo`.
        public var undo: UndoOutcome?
        /// `true` when something actually changed on the machine, so the caller
        /// refreshes its caches.
        public var changed = false
        /// Whether the caller should tell the operator. Reserved for the one
        /// case that needs a human: processes left stopped.
        public var shouldNotify = false
        public var notice: Notice?
        /// The journal could not be persisted. Reported, never swallowed: an
        /// action journal that does not land cannot be undone, so the caller
        /// must not present the apply as safe.
        public var journalSaveFailed = false
        /// Pids stopped by this step.
        public var stoppedPids: [Int32] = []
        /// Pids resumed by this step.
        public var resumedPids: [Int32] = []
        /// Pids whose identity could not be re-proved, left stopped on purpose.
        public var unverifiedPids: [Int32] = []
        /// An audio device that no longer exists at undo time. Not an error
        /// (ADR 026): noted and skipped.
        public var audioDeviceGone = false
    }

    public enum Notice: String, Sendable, Equatable {
        /// Some apps are still paused because their identity changed, or the
        /// `SIGCONT` could not be confirmed. The operator has to look.
        case appsLeftPaused
        /// An output device we muted is unreachable, so the restore could not
        /// be proved. The operator has to check their sound.
        case audioLeftMuted
    }

    // MARK: — Evaluate

    /// The live readings the shared tick feeds to `step`.
    ///
    /// Bundled rather than passed as four arguments because they travel
    /// together and because the CLI's read-only `status` reports exactly the
    /// same tuple: one shape, one place where a reading can be wrong.
    public struct Readings: Sendable {
        /// `session.json` as loaded.
        public var session: KeepAwakeSession?
        /// `AppleClamshellState` (`nil` = unreadable).
        public var lidClosed: Bool?
        /// An online non-built-in display (`nil` = unreadable).
        public var externalDisplayConnected: Bool?
        public var settings: LidCloseActionSettings

        public init(session: KeepAwakeSession?, lidClosed: Bool?,
                    externalDisplayConnected: Bool?, settings: LidCloseActionSettings) {
            self.session = session
            self.lidClosed = lidClosed
            self.externalDisplayConnected = externalDisplayConnected
            self.settings = settings
        }

        /// The live production readings.
        public static func live(session: KeepAwakeSession?) -> Readings {
            var r = lidEnvironment()
            r.session = session
            return r
        }

        /// Everything EXCEPT the session, which a caller holding a
        /// `SessionService` supplies itself (the service is not `Sendable`, so
        /// it cannot travel inside a `@Sendable` closure).
        public static func lidEnvironment() -> Readings {
            Readings(session: nil,
                     lidClosed: ClamshellReadback.lidClosed(),
                     externalDisplayConnected: ClamshellReadback.externalDisplayConnected(),
                     settings: LidCloseActionSettingsStore.load())
        }
    }

    /// Read-only evaluation: no mutation, no journal write, no audit line.
    public func evaluate(sessionActive: Bool, lidClosed: Bool?,
                         externalDisplayConnected: Bool?,
                         settings: LidCloseActionSettings) -> Evaluation {
        let record = journal.load()
        let input = LidCloseActionPolicy.Input(
            sessionActive: sessionActive,
            lidClosed: lidClosed,
            externalDisplayConnected: externalDisplayConnected,
            settings: settings)
        // `currentlyApplied` covers the OBLIGATIONS too, not just the live
        // effects. A record whose `stopped` list is empty but whose `unverified`
        // list is not still needs the operator, so it must keep steering the
        // step into `.undo` (which re-raises the notice) instead of falling to
        // "nothing of ours" and going quiet (caught by ai-review-gate).
        let outstanding = !record.isEmpty || !record.unverified.isEmpty
        return Evaluation(
            input: input,
            decision: LidCloseActionPolicy.decide(input, currentlyApplied: outstanding),
            journalBefore: record)
    }

    // MARK: — Step

    /// Undo every journaled effect NOW, whatever the conditions say.
    ///
    /// Called at four points, all of which the plan names (ADR 026):
    ///
    /// - immediately BEFORE a protective release or sleep (the thermal and
    ///   low-battery branches), so the Mac does not go down muted with an app
    ///   frozen — the undo has to happen before the release, not after the
    ///   wake-up that may never come;
    /// - on the app's quit teardown;
    /// - by the ADR 024 backstop, so a Mac whose app crashed does not stay mute
    ///   with a frozen app;
    /// - by the ordinary tick, once the conditions stop holding.
    ///
    /// Idempotent, and never an error when there is nothing to undo.
    @discardableResult
    public mutating func undoAll() -> TickOutcome {
        let record = journal.load()
        // A synthetic evaluation: the undo path only needs the journal, and
        // the readings it records in the audit line are the ones we have not
        // taken here. `nil` renders as "unknown", which is honest.
        let evaluation = Evaluation(
            input: LidCloseActionPolicy.Input(
                sessionActive: false, lidClosed: nil, externalDisplayConnected: nil,
                settings: LidCloseActionSettings()),
            decision: LidCloseActionPolicy.Decision(action: .undo, reason: .applied),
            journalBefore: record)
        var outcome = TickOutcome(evaluation: evaluation)
        // `unverified` counts: a process we could not prove is still an
        // outstanding obligation, and returning `.nothingToDo` on a record that
        // holds only those silenced the operator notice forever (gate finding,
        // `Persisted unverified processes stop raising attention`).
        guard !record.isEmpty || !record.unverified.isEmpty
                || record.unverifiedAudio != nil else {
            outcome.undo = .nothingToDo
            return outcome
        }
        undo(evaluation: evaluation, into: &outcome)
        return outcome
    }

    /// One step. Takes no lock (caller holds `LidWriteLock`).
    ///
    /// The session is passed as the RECORD, not as a boolean, because "is it
    /// running" is two facts (a record exists, and it is not paused) and the
    /// caller already has the object.
    @discardableResult
    public mutating func step(session: KeepAwakeSession?, lidClosed: Bool?,
                              externalDisplayConnected: Bool?,
                              settings: LidCloseActionSettings) -> TickOutcome {
        currentSessionIdentity = session?.id
        return step(sessionActive: LidCloseActionPolicy.sessionIsActive(session),
                    lidClosed: lidClosed,
                    externalDisplayConnected: externalDisplayConnected,
                    settings: settings)
    }

    @discardableResult
    public mutating func step(readings: Readings) -> TickOutcome {
        step(session: readings.session, lidClosed: readings.lidClosed,
             externalDisplayConnected: readings.externalDisplayConnected,
             settings: readings.settings)
    }

    @discardableResult
    public mutating func step(sessionActive: Bool, lidClosed: Bool?,
                              externalDisplayConnected: Bool?,
                              settings: LidCloseActionSettings) -> TickOutcome {
        let evaluation = evaluate(sessionActive: sessionActive, lidClosed: lidClosed,
                                  externalDisplayConnected: externalDisplayConnected,
                                  settings: settings)
        var outcome = TickOutcome(evaluation: evaluation)
        switch evaluation.decision.action {
        case .none:
            break
        case .apply:
            apply(evaluation: evaluation, into: &outcome)
        case .undo:
            undo(evaluation: evaluation, into: &outcome)
        }
        return outcome
    }

    // MARK: — Apply

    /// JOURNAL BEFORE CHANGE, effect by effect, and each effect recorded only
    /// once it is readback-confirmed (B3: write from the OUTCOME).
    ///
    /// An effect that could not be proved is removed from the journal rather
    /// than kept "just in case": an entry authorises the undo to reverse
    /// something, so an entry for an effect that never happened would make the
    /// undo un-mute a device the operator muted themselves, or `SIGCONT` a
    /// process we never paused.
    private mutating func apply(evaluation: Evaluation, into outcome: inout TickOutcome) {
        let decision = evaluation.decision
        // Neither effect is switched on. That is NOT a shortcut past the undo:
        // with both switches off there may still be something to reverse, and
        // the per-effect block below is the only thing that can do it.
        guard decision.muteAudio || decision.pauseApps else {
            undoEffectsThatAreNowOff(evaluation: evaluation, into: &outcome)
            // `.nothingRequested` only when nothing was actually reversed.
            if outcome.apply == nil { outcome.apply = .nothingRequested }
            return
        }

        var record = evaluation.journalBefore
        record.sessionID = currentSessionIdentity
        record.startedAt = ISO8601DateFormatter().string(from: wallClock())

        // Effects whose own switch is now off are reversed first, on the
        // record we just loaded, so the rest of `apply` works on a clean slate.
        undoEffectsThatAreNowOff(evaluation: evaluation, into: &outcome)
        record = outcome.evaluation.journalBefore

        var audioEffect = AudioEffect.skipped
        var audioError: String?
        var appsEffect = AppsEffect.skipped
        var appError: String?

        // A device that was concluded gone and has come BACK still holding its
        // mute state: re-adopt the obligation instead of forgetting it, so the
        // undo can restore it (gate finding, `Temporary device absence
        // permanently discards restoration`).
        if decision.muteAudio, record.audio == nil,
           let stranded = record.unverifiedAudio,
           let back = audio.readOutput(uid: stranded.deviceUID), back.isMuted != false {
            record.audio = stranded
            record.unverifiedAudio = nil
            journal.save(record)
        }

        // — 1. Sound.
        if decision.muteAudio, record.audio == nil {
            switch muteDefaultOutput(journal: &record) {
            case .success(let effect):
                audioEffect = effect
            case .failure(let error):
                audioError = error
                audioEffect = .failed
            case .journalFailed:
                outcome.journalSaveFailed = true
                audioEffect = .failed
                audioError = "the journal could not be written"
            }
        } else if decision.muteAudio {
            audioEffect = .alreadyRecorded
        }

        // — 2. Apps, only if the sound step did not already fail the journal.
        if decision.pauseApps, !outcome.journalSaveFailed {
            switch stopMatchingApps(names: decision.appNames, journal: &record,
                                    into: &outcome) {
            case .success(let effect):
                appsEffect = effect
            case .failure(let error):
                appError = error
                appsEffect = .failed
            case .journalFailed:
                outcome.journalSaveFailed = true
                appsEffect = .failed
                appError = "the journal could not be written"
            }
        }

        // Persist the OUTCOME (B3) — including the `unverified` list, which is
        // whatever the previous episode left and must survive this one.
        if !journal.save(record) { outcome.journalSaveFailed = true }
        outcome.evaluation.journalBefore = record

        outcome.apply = combine(audio: decision.muteAudio ? audioEffect : .skipped,
                                apps: decision.pauseApps ? appsEffect : .skipped)
        outcome.changed = audioEffect == .muted || appsEffect == .stopped
        writeAudit(outcome: outcome.apply?.rawValue ?? "none",
                   reason: decision.reason.rawValue,
                   evaluation: evaluation,
                   audio: audioEffect.rawValue, audioError: audioError,
                   audioDeviceUID: record.audio?.deviceUID,
                   stopped: outcome.stoppedPids, failed: [], error: appError)
    }

    /// Mute the default output, journaling its prior state first.
    ///
    /// Returns `.success(.alreadyMuted)` without writing when the device was
    /// ALREADY silent — and then journals nothing at all, because the undo must
    /// not turn sound back on that the operator had turned off.
    private mutating func muteDefaultOutput(
        journal record: inout LidCloseActionJournal.Record
    ) -> EffectResult<AudioEffect> {
        // No readable default output, or one that cannot be muted: nothing is
        // written and nothing is journaled. An effect we cannot name is an
        // effect we cannot undo (ADR 009).
        guard let snapshot = audio.readDefaultOutput(), snapshot.canMute else {
            return .failure("no murable default output device")
        }
        // An unreadable prior state is not a licence to write: the undo would
        // be a guess (ADR 009).
        guard let wasMuted = snapshot.isMuted else {
            return .failure("the device's mute state could not be read")
        }
        guard !wasMuted else { return .success(.alreadyMuted) }

        record.audio = LidCloseActionJournal.AudioState(
            deviceUID: snapshot.uid, wasMuted: false, volume: snapshot.volume)
        guard journal.save(record) else {
            record.audio = nil
            return .journalFailed
        }
        audio.setMuted(true, uid: snapshot.uid)
        // Acceptance is not proof (ADR 009): read back before claiming it.
        //
        // Three cases, not two. An UNREADABLE readback (`nil`) is not evidence
        // that the effect did not happen, and dropping the entry on it would
        // leave a device muted with nothing authorising the undo (caught by
        // ai-review-gate). Only a POSITIVE reading of "still audible" proves
        // nothing changed. So: unreadable keeps the entry and reports the
        // effect as unconfirmed; audible-only drops it.
        switch audio.readOutput(uid: snapshot.uid)?.isMuted {
        case .some(true):
            return .success(.muted)
        case .some(false):
            // Proved still audible: nothing was written, so the entry goes.
            record.audio = nil
            journal.save(record)
            return .failure("readback did not confirm the mute")
        case .none:
            // Unreadable is not proof of absence: keep the entry.
            return .failure("the mute could not be verified (readback unreadable)")
        }
    }

    /// `SIGSTOP` every process matching `names`, journaling the identity TRIPLE
    /// of each one before the signal.
    private mutating func stopMatchingApps(
        names: [String],
        journal record: inout LidCloseActionJournal.Record,
        into outcome: inout TickOutcome
    ) -> EffectResult<AppsEffect> {
        let targets = processes.runningProcesses(matching: names)
        let known = Set(record.stopped.map { $0.pid })
        let pending = targets
            .map { $0.journalEntry(bootID: bootID) }
            .filter { !known.contains($0.pid) }
        guard !pending.isEmpty else { return .success(.stopped) }

        var stopped: [LidCloseActionJournal.StoppedProcess] = []
        var failed: [Int32] = []
        for entry in pending {
            // JOURNAL THIS ONE, THEN SIGNAL IT — one at a time.
            //
            // Batching the whole target set ahead of the loop looked safer
            // ("a crash mid-loop still leaves the identities") but it granted
            // resume ownership over processes this run never signalled: a crash
            // on process 2 of 5 left 3, 4 and 5 recorded as ours, and if the
            // operator later paused one of them the undo would `SIGCONT` an app
            // RunClosed never touched (gate finding). Journaling per process
            // keeps the crash-safety property for exactly the entries that were
            // signalled.
            record.stopped.append(entry)
            guard journal.save(record) else {
                record.stopped.removeAll { $0.pid == entry.pid }
                return .journalFailed
            }
            // RE-PROVE the identity immediately before signalling. The
            // snapshot `runningProcesses` returned may be stale: the app can
            // exit and the kernel can hand the same pid to something else
            // between the enumeration and this line, and `LidWriteLock` does
            // not serialise process exit. Signalling the replacement would
            // suspend an unrelated process while the journal records the
            // original identity, and the undo would refuse to resume it
            // (gate finding).
            guard identityProved(entry) else {
                failed.append(entry.pid)
                record.stopped.removeAll { $0.pid == entry.pid }
                journal.save(record)
                continue
            }
            processes.stop(pid: entry.pid)
            // `kill(2)` returning 0 means "delivered", not "stopped", and the
            // transition is not instantaneous: a single immediate read can
            // legitimately still see it running. Deleting the entry on that
            // reading is what orphaned a genuinely-stopped process (gate
            // finding), so the confirmation is RETRIED before it is believed.
            switch confirmStopped(pid: entry.pid) {
            case .some(true):
                stopped.append(entry)
            case .some(false):
                // Proved still running after the retries: the signal did not
                // take, so the journal must not claim it (an entry would let
                // the undo `SIGCONT` a process we never paused).
                failed.append(entry.pid)
                record.stopped.removeAll { $0.pid == entry.pid }
            case .none:
                // UNREADABLE is not proof of absence: keep the entry so the
                // undo can re-prove and reverse it.
                failed.append(entry.pid)
            }
        }
        outcome.stoppedPids = stopped.map { $0.pid }
        guard failed.isEmpty else {
            return .failure("could not stop \(failed.count) process(es): \(failed)")
        }
        return .success(.stopped)
    }

    /// Read an output device, retrying once before believing it is gone.
    ///
    /// "Gone" is a destructive conclusion: it clears the journal entry and
    /// nothing will retry. A single flaky read must not reach it, so an
    /// unreadable first read is retried after the same short delay the stop
    /// confirmation uses.
    private func readOutputTwice(uid: String) -> AudioOutputSnapshot? {
        if let snap = audio.readOutput(uid: uid) { return snap }
        stopConfirmDelay()
        return audio.readOutput(uid: uid)
    }

    /// Read the stopped state, retrying briefly.
    ///
    /// `SIGSTOP` is asynchronous: the process has to be scheduled to reach
    /// `SSTOP`. A single immediate read races that transition and can report
    /// "still running" for a signal that is about to take effect — which is
    /// exactly how a stopped app lost its journal entry and could never be
    /// resumed (gate finding). The interval is injectable so the tests stay
    /// deterministic and no test sleeps.
    private func confirmStopped(pid: Int32) -> Bool? {
        var last: Bool?
        for attempt in 0..<Self.stopConfirmAttempts {
            last = processes.isStopped(pid: pid)
            if last == true { return true }
            guard attempt + 1 < Self.stopConfirmAttempts else { break }
            stopConfirmDelay()
        }
        return last
    }

    /// How many times the stopped state is read before it is believed.
    static let stopConfirmAttempts = 5

    /// How many SEPARATE undo passes a device must stay unreadable before it is
    /// concluded removed. Three hours of 30 s ticks is far past any transient.
    static let unreadablePassesBeforeGone = 360

    /// The wait between those reads. Production sleeps 20 ms (5 × 20 ms = the
    /// sub-100 ms window a `SIGSTOP` needs); tests replace it with a no-op.
    public var stopConfirmDelay: @Sendable () -> Void = { usleep(20_000) }

    /// Undo the effects whose OWN switch is now off.
    ///
    /// Each switch owns its effect, so each switch must be able to reverse it:
    /// turning off "Mute the sound" (or "Pause noisy apps") while the session
    /// continues used to leave that effect in place until the master switch or
    /// the conditions changed (gate finding, `Disabling an individual effect
    /// does not restore it`).
    ///
    /// Shared by both entries into `apply` — the normal one and the
    /// "both switches off" one — so neither can skip it.
    private mutating func undoEffectsThatAreNowOff(
        evaluation: Evaluation, into outcome: inout TickOutcome
    ) {
        let decision = evaluation.decision
        var record = outcome.evaluation.journalBefore

        if !decision.muteAudio, record.audio != nil {
            var scratch = TickOutcome(evaluation: evaluation)
            unmuteRecordedDevice(journal: &record, into: &scratch)
            if scratch.audioDeviceGone { outcome.audioDeviceGone = true }
            if scratch.changed { outcome.changed = true }
            outcome.evaluation.journalBefore = record
        }
        if !decision.pauseApps, !record.stopped.isEmpty {
            var scratch = TickOutcome(evaluation: evaluation)
            resumeStoppedProcesses(journal: &record, into: &scratch)
            if scratch.changed { outcome.changed = true }
            if scratch.shouldNotify {
                outcome.shouldNotify = true
                outcome.notice = scratch.notice
                outcome.unverifiedPids = scratch.unverifiedPids
            }
            outcome.evaluation.journalBefore = record
        }
        // Any reversal is an effect, not "nothing requested".
        if outcome.changed { outcome.apply = outcome.apply ?? .applied }
    }

    private enum AudioEffect: String, Sendable {
        case muted
        case alreadyMuted
        case alreadyRecorded
        case failed
        case skipped
    }

    private enum AppsEffect: String, Sendable {
        case stopped
        case failed
        case skipped
    }

    /// Combine the two effects into one word for the caller and the audit.
    private func combine(audio: AudioEffect, apps: AppsEffect) -> ApplyOutcome {
        let audioOK = audio == .muted || audio == .alreadyMuted || audio == .alreadyRecorded
        let appsOK = apps == .stopped
        let audioAsked = audio != .skipped
        let appsAsked = apps != .skipped
        let asked = [audioAsked, appsAsked].filter { $0 }.count
        let ok = [audioAsked && audioOK, appsAsked && appsOK].filter { $0 }.count
        if asked == 0 { return .nothingRequested }
        if ok == asked { return .applied }
        return ok == 0 ? .failed : .partial
    }

    /// Three-way result for one effect: done, refused with a reason, or the
    /// journal could not record it (which makes the effect illegal, because it
    /// could not be undone).
    private enum EffectResult<T> {
        case success(T)
        case failure(String)
        case journalFailed
    }

    // MARK: — Undo

    /// The reverse order, everywhere (ADR 026): apps (`SIGCONT`) then sound.
    /// Screen and keyboard are not part of this lot.
    private mutating func undo(evaluation: Evaluation, into outcome: inout TickOutcome) {
        var record = evaluation.journalBefore
        // `unverified` entries are OBLIGATIONS, not live effects: a record
        // holding only those must still reach the notice below rather than
        // reading as "nothing of ours".
        guard !record.isEmpty || !record.unverified.isEmpty
                || record.unverifiedAudio != nil else {
            // Nothing of ours is applied. Not an error (idempotence): a lid
            // closed twice, or an undo with no prior action, is a no-op.
            outcome.undo = .nothingToDo
            return
        }

        // — 1. Apps first: resume what we stopped, never what we did not.
        resumeStoppedProcesses(journal: &record, into: &outcome)
        // A resume that did not take keeps its journal entry for the next step
        // to retry, and that is reported — but it does NOT abort the undo.
        //
        // Aborting here was a real defect: a wedged app (a `SIGCONT` delivered,
        // the process still stopped) would leave the Mac MUTED as well, so one
        // broken effect compounded into two. The order is apps-then-sound, not
        // apps-OR-sound: the sound restore is independent and must still run.
        let appsStuck = !record.stopped.isEmpty

        // — 2. Sound.
        unmuteRecordedDevice(journal: &record, into: &outcome)

        outcome.undo = finish(journal: &record, appsStuck: appsStuck)
        outcome.evaluation.journalBefore = record
    }

    /// `SIGCONT` each journaled process whose identity is RE-PROVED.
    ///
    /// A process whose identity cannot be proved — a recycled pid, a vanished
    /// process, a different boot — is moved to `unverified` and left alone.
    /// Resuming the wrong process is strictly worse than leaving an app paused
    /// (ADR 026), so the doubt never resumes.
    private mutating func resumeStoppedProcesses(
        journal record: inout LidCloseActionJournal.Record,
        into outcome: inout TickOutcome
    ) {
        // Nothing NEW to resume, but an obligation carried from an earlier pass
        // still has to be reported. Returning here silenced the notice on the
        // second pass, when `stopped` was already empty and only `unverified`
        // remained (gate finding, `Persisted unverified processes stop raising
        // attention`).
        guard !record.stopped.isEmpty else {
            if !record.unverified.isEmpty || record.unverifiedAudio != nil {
                outcome.unverifiedPids = record.unverified.map { $0.pid }
                outcome.shouldNotify = true
                outcome.notice = record.unverified.isEmpty ? .audioLeftMuted : .appsLeftPaused
            }
            return
        }
        var remaining: [LidCloseActionJournal.StoppedProcess] = []
        var resumed: [Int32] = []
        var unverified: [LidCloseActionJournal.StoppedProcess] = []
        var failed: [Int32] = []

        for entry in record.stopped {
            guard identityProved(entry) else {
                unverified.append(entry)
                continue
            }
            processes.resume(pid: entry.pid)
            if processes.isStopped(pid: entry.pid) == false {
                resumed.append(entry.pid)
            } else {
                // The signal did not take: keep it for the next step rather
                // than claiming a restore that did not happen.
                failed.append(entry.pid)
                remaining.append(entry)
            }
        }
        record.stopped = remaining
        // "To verify" survives the episode: the operator has to be told about a
        // process we can no longer identify, and it must not be silently
        // dropped by the next apply. De-duplicated by pid so a process moved
        // here twice (recycled, then found again) is listed once.
        for entry in unverified where !record.unverified.contains(where: { $0.pid == entry.pid }) {
            record.unverified.append(entry)
        }
        journal.save(record)

        outcome.resumedPids = resumed
        // The WHOLE outstanding list, not only what this pass happened to
        // discover: the caller and the operator care about every process still
        // waiting on them.
        outcome.unverifiedPids = record.unverified.map { $0.pid }
        if !resumed.isEmpty { outcome.changed = true }
        // Any outstanding obligation keeps raising the notice, including one
        // carried over from an earlier pass — otherwise the second step through
        // here goes silent while the operator is still owed an answer.
        if !record.unverified.isEmpty || !remaining.isEmpty {
            outcome.shouldNotify = true
            outcome.notice = .appsLeftPaused
        }
        writeAudit(outcome: failed.isEmpty && unverified.isEmpty ? "undone" : "partial",
                   reason: "undo",
                   evaluation: outcome.evaluation,
                   audio: nil, audioError: nil, audioDeviceUID: nil,
                   stopped: [], failed: failed, error: nil,
                   resumed: resumed, unverified: unverified.map { $0.pid })
    }

    /// Un-mute ONLY what we muted.
    ///
    /// The device is looked up by UID: it may have gone (unplugged headphones, a
    /// switched output), which is noted, not an error (ADR 026). And if it was
    /// already muted before we arrived, there is nothing of ours to restore —
    /// un-muting would be an effect the operator never asked for.
    private mutating func unmuteRecordedDevice(
        journal record: inout LidCloseActionJournal.Record,
        into outcome: inout TickOutcome
    ) {
        guard let prior = record.audio else { return }
        // An unreadable device is NOT a removed device. The apply path already
        // makes that distinction; the undo path used to collapse both into
        // `nil`, drop the entry and report `deviceGone`, which left a muted
        // device with nothing to retry from (gate finding). Two reads tell a
        // transient failure from a real removal.
        guard let current = readOutputTwice(uid: prior.deviceUID) else {
            // Still unreadable after the retry. That is NOT proof the device
            // was removed: clearing the entry here left a muted device with no
            // retry left. So the obligation STAYS, and the conclusion "gone" is
            // only drawn after the device stays unreadable across several
            // SEPARATE passes — a flaky read must never strand it, and a single
            // failure must never be read as removal (gate findings).
            var escalated = prior
            escalated.unreadablePasses += 1
            if escalated.unreadablePasses >= Self.unreadablePassesBeforeGone {
                // Concluding "gone" DROPS the obligation, and a device can come
                // back: headphones muted here, unplugged for three hours and
                // plugged in again still holding their mute state would find no
                // record and stay silent (gate finding, `Temporary device
                // absence permanently discards restoration`).
                //
                // So the obligation moves to `unverified` instead of vanishing.
                // It stops driving the undo (the device is not reachable, so
                // there is nothing to do) but it SURVIVES: it is reported to the
                // operator, and if the same UID reappears still muted the next
                // apply re-adopts it rather than forgetting it.
                record.audio = nil
                record.unverifiedAudio = escalated
                journal.save(record)
                outcome.audioDeviceGone = true
                writeAudit(outcome: "deviceGone", reason: "undo",
                           evaluation: outcome.evaluation, audio: "gone",
                           audioError: "unreadable on \(escalated.unreadablePasses) separate passes; kept as unverified",
                           audioDeviceUID: prior.deviceUID, stopped: [], failed: [], error: nil)
                return
            }
            record.audio = escalated
            journal.save(record)
            writeAudit(outcome: "partial", reason: "undo", evaluation: outcome.evaluation,
                       audio: "readUnavailable",
                       audioError: "the device could not be read; the restore is unconfirmed",
                       audioDeviceUID: prior.deviceUID, stopped: [], failed: [], error: nil)
            return
        }
        guard !prior.wasMuted else {
            // Silent before we arrived: leave it silent.
            record.audio = nil
            journal.save(record)
            writeAudit(outcome: "undone", reason: "undo", evaluation: outcome.evaluation,
                       audio: "leftMuted", audioError: nil, audioDeviceUID: prior.deviceUID,
                       stopped: [], failed: [], error: nil)
            return
        }
        // Still muted is what we asked for; anything else means someone else
        // touched it in the meantime, in which case we do not write either.
        // Only a POSITIVE "audible" proves someone else already did our job.
        // An unreadable flag is not that proof, so we fall through and write.
        if current.isMuted == false {
            record.audio = nil
            journal.save(record)
            writeAudit(outcome: "undone", reason: "undo", evaluation: outcome.evaluation,
                       audio: "alreadyAudible", audioError: nil,
                       audioDeviceUID: prior.deviceUID, stopped: [], failed: [], error: nil)
            return
        }
        audio.setMuted(false, uid: prior.deviceUID)
        // Readback, not acceptance: only a device that reads audible is
        // restored (ADR 009).
        guard audio.readOutput(uid: prior.deviceUID)?.isMuted == false else {
            writeAudit(outcome: "partial", reason: "undo", evaluation: outcome.evaluation,
                       audio: "unmuteFailed",
                       audioError: "readback did not confirm the unmute",
                       audioDeviceUID: prior.deviceUID, stopped: [], failed: [], error: nil)
            return
        }
        record.audio = nil
        journal.save(record)
        outcome.changed = true
        writeAudit(outcome: "undone", reason: "undo", evaluation: outcome.evaluation,
                   audio: "unmuted", audioError: nil, audioDeviceUID: prior.deviceUID,
                   stopped: [], failed: [], error: nil)
    }

    /// Clear the journal once nothing of ours is outstanding.
    ///
    /// `unverified` is deliberately NOT part of `isEmpty`: a process we could
    /// not prove is still an outstanding obligation, so the file stays and the
    /// notice keeps being raised until the operator deals with it.
    ///
    /// `appsStuck` carries the one fact this function cannot read off the record:
    /// a process whose entry is still in `stopped` because its `SIGCONT` did not
    /// take. That is a retryable failure and an `.incomplete` undo, never
    /// `.restored` just because the SOUND came back.
    private func finish(journal record: inout LidCloseActionJournal.Record,
                        appsStuck: Bool) -> UndoOutcome {
        if record.isEmpty && record.unverified.isEmpty && !appsStuck
            && record.unverifiedAudio == nil {
            // The delete must be PROVED too. `clear()` is best effort, and a
            // silent failure here leaves stale ownership on disk that a later
            // undo could act on — reversing something the operator did
            // themselves (caught by ai-review-gate). A record that is still
            // present after the clear is an incomplete restore, not a
            // successful one.
            journal.clear()
            return journal.load().isEmpty && journal.load().unverified.isEmpty
                ? .restored : .incomplete
        }
        // A save that does not land leaves the PREVIOUS record on disk, so the
        // undo did not reach a state anyone can rely on.
        guard journal.save(record) else { return .incomplete }
        if appsStuck { return .incomplete }
        return record.isEmpty ? .unverifiedProcesses : .incomplete
    }

    /// Is the process behind `entry.pid` still the one we stopped?
    ///
    /// The triple must match — pid, start time and boot. Anything else means the
    /// pid may have been recycled, and a recycled pid is NOT our process.
    private func identityProved(_ entry: LidCloseActionJournal.StoppedProcess) -> Bool {
        // A start time from another boot is not comparable: refuse.
        guard entry.bootID == bootID else { return false }
        guard let current = processes.identity(ofPid: entry.pid) else { return false }
        return current.pid == entry.pid
            && current.startSeconds == entry.startSeconds
            && current.startMicroseconds == entry.startMicroseconds
            && current.bootID == entry.bootID
    }

    // MARK: — Plumbing

    private func writeAudit(outcome: String, reason: String, evaluation: Evaluation,
                            audio: String?, audioError: String?,
                            audioDeviceUID: String?,
                            stopped: [Int32], failed: [Int32], error: String?,
                            resumed: [Int32] = [], unverified: [Int32] = []) {
        auditLog.append(.init(
            ts: ISO8601DateFormatter().string(from: wallClock()),
            bootID: bootID,
            outcome: outcome,
            reason: reason,
            lid: Self.triState(evaluation.input.lidClosed, yes: "closed", no: "open"),
            externalDisplay: Self.triState(
                evaluation.input.externalDisplayConnected, yes: "connected", no: "none"),
            sessionActive: evaluation.input.sessionActive,
            audio: audio,
            audioDeviceUID: audioDeviceUID,
            audioError: audioError,
            stoppedPids: stopped.isEmpty ? nil : stopped,
            resumedPids: resumed.isEmpty ? nil : resumed,
            unverifiedPids: unverified.isEmpty ? nil : unverified,
            failedPids: failed.isEmpty ? nil : failed,
            appError: error))
    }

    private static func triState(_ value: Bool?, yes: String, no: String) -> String {
        guard let value else { return "unknown" }
        return value ? yes : no
    }
}
