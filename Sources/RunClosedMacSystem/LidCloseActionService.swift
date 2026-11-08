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
        /// The sound could not be restored this pass (the entry is kept for a
        /// retry). Distinguished from "nothing to do", so the caller never
        /// reports a clean outcome over a Mac that is still silent.
        public var audioRestoreFailed = false
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
            || !record.unverifiedAudio.isEmpty
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
                || !record.unverifiedAudio.isEmpty else {
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
        if decision.muteAudio, let stranded = firstReturnedStrandedDevice(&record) {
            if !record.audio.contains(where: { $0.deviceUID == stranded.deviceUID }) {
                record.audio.append(stranded)
            }
            journal.save(record)
        }

        // — 1. Sound. The CURRENT default output is muted whenever it is not
        // already covered by a journal entry.
        //
        // Gating this on "the journal is empty" was wrong: if the operator plugs
        // headphones in mid-session, the journal already holds the OLD device,
        // so the new default output was never muted and stayed audible while the
        // service reported the action applied (Lord review round 4).
        if decision.muteAudio, !isCurrentDefaultOutputRecorded(record) {
            switch muteDefaultOutput(journal: &record) {
            case .success(let effect):
                audioEffect = effect
            case .failure(let error):
                audioError = error
                // An UNCONFIRMED write is not "no change": the acceptance
                // happened, so the machine may be muted now.
                audioEffect = error.hasPrefix("UNCONFIRMED") ? .unconfirmed : .failed
                if audioEffect == .unconfirmed { outcome.changed = true }
            case .journalFailed(let stoppedSoFar):
                outcome.journalSaveFailed = true
                outcome.stoppedPids = stoppedSoFar
                if !stoppedSoFar.isEmpty { outcome.changed = true }
                audioEffect = .failed
                audioError = "the journal could not be written"
            }
        } else if decision.muteAudio {
            // The entry exists, but that is not evidence the MUTE landed: a
            // write whose readback was unavailable keeps its journal entry
            // (correct) and then every later pass reported `applied` without
            // ever reading the device again — leaving the sound audible for the
            // whole closed-lid session (gate finding, `Unconfirmed mute is
            // subsequently treated as applied without readback`).
            //
            // So an existing entry is CONFIRMED, not assumed.
            audioEffect = confirmExistingMute(record: record)
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
            case .journalFailed(let stoppedSoFar):
                // Processes ALREADY stopped must not be hidden by the failed
                // write: they are frozen on the machine, so the caller needs
                // their pids and the "something changed" signal (gate finding,
                // `Un échec de journal masque les processus déjà suspendus`).
                outcome.journalSaveFailed = true
                outcome.stoppedPids = stoppedSoFar
                if !stoppedSoFar.isEmpty { outcome.changed = true }
                appsEffect = stoppedSoFar.isEmpty ? .failed : .partial
                appError = "the journal could not be written"
            }
        }

        // Persist the OUTCOME (B3) — including the `unverified` list, which is
        // whatever the previous episode left and must survive this one.
        if !journal.save(record) { outcome.journalSaveFailed = true }
        outcome.evaluation.journalBefore = record

        outcome.apply = combine(audio: decision.muteAudio ? audioEffect : .skipped,
                                apps: decision.pauseApps ? appsEffect : .skipped)
        // OR, never assign: `undoEffectsThatAreNowOff` may already have reversed
        // something, and a partial stop DID freeze a process. Assigning here
        // erased both, so callers refeshing their caches kept stale state
        // (gate finding, `Change reporting loses partial stops and successful
        // reversals`).
        outcome.changed = outcome.changed
            || audioEffect == .muted
            || audioEffect == .unconfirmed
            || appsEffect == .stopped
            || appsEffect == .partial
        writeAudit(outcome: outcome.apply?.rawValue ?? "none",
                   reason: decision.reason.rawValue,
                   evaluation: evaluation,
                   audio: audioEffect.rawValue, audioError: audioError,
                   audioDeviceUID: record.audio.first?.deviceUID,
                   stopped: outcome.stoppedPids, failed: [], error: appError)
    }

    /// Is the CURRENT default output already covered by a journal entry?
    ///
    /// `true` when we have already accounted for it (either we muted it, or it
    /// was muted before we arrived); `false` when it is a NEW device the
    /// operator just selected.
    private func isCurrentDefaultOutputRecorded(_ record: LidCloseActionJournal.Record) -> Bool {
        // Unknown default output is NOT "already handled": letting it read as
        // covered made the mute path report `.applied` with no device at all
        // (a no-op presented as success). `false` lets `muteDefaultOutput` run
        // and fail honestly, which is what "no murable device" should say.
        guard let snapshot = audio.readDefaultOutput() else { return false }
        return record.audio.contains { $0.deviceUID == snapshot.uid }
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

        // APPEND, never assign: another device may already be recorded from
        // earlier in the session, and overwriting it would lose its undo.
        let entry = LidCloseActionJournal.AudioState(
            deviceUID: snapshot.uid, wasMuted: false, volume: snapshot.volume)
        record.audio.removeAll { $0.deviceUID == snapshot.uid }
        record.audio.append(entry)
        guard journal.save(record) else {
            removeAudio(snapshot.uid, in: &record)
            return .journalFailed(stoppedSoFar: [])
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
            removeAudio(snapshot.uid, in: &record)
            journal.save(record)
            return .failure("readback did not confirm the mute")
        case .none:
            // Unreadable is not proof of absence: keep the entry. The write
            // itself was ACCEPTED, so the machine may well have changed — report
            // the uncertainty rather than a clean "nothing happened" (gate
            // finding, `An actual mute can be reported as no machine change`).
            return .failure("UNCONFIRMED: the mute could not be verified (readback unreadable)")
        }
    }

    /// `SIGSTOP` every process matching `names`, journaling the identity TRIPLE
    /// of each one before the signal.
    private mutating func stopMatchingApps(
        names: [String],
        journal record: inout LidCloseActionJournal.Record,
        into outcome: inout TickOutcome
    ) -> EffectResult<AppsEffect> {
        // An app the operator just UNTICKED is no longer in `names`, so nothing
        // below would ever resume it — it would stay frozen for the rest of the
        // session (Lord review round 4). Resume every journaled app that is no
        // longer selected, when its identity is proved.
        var resumedDropped: [Int32] = []
        var droppedUnproved = false

        // De-selected apps sitting in `unverified` too: a stop that timed out
        // may have landed afterwards, and once the app is dropped from the
        // selection nothing else would ever look at it — it would stay frozen
        // (gate finding, `Deselecting an app does not recover its unverified
        // stop`).
        // Entries for apps STILL selected are none of this block's business:
        // they stay listed (the normal path keeps reporting them).
        var stillUnverified = record.unverified.filter { names.contains($0.appName) }
        for entry in record.unverified where !names.contains(entry.appName) {
            guard identityProved(entry) else {
                stillUnverified.append(entry)
                droppedUnproved = true
                continue
            }
            // A pending SIGSTOP may not have landed yet: `isStopped == false`
            // does NOT mean the process is free of our signal, only that the
            // transition is not visible. Sending `SIGCONT` is the right move
            // here (it is a no-op on a running process and cancels the pending
            // stop), but dropping the entry on that reading is not: if the
            // signal lands afterwards the app is frozen with nothing to recover
            // it (gate finding, `Deselecting an app discards recovery for a
            // pending SIGSTOP`).
            if processes.isStopped(pid: entry.pid) == true {
                processes.resume(pid: entry.pid)
            } else {
                // Cancel the pending stop, then re-read: only a POSITIVE
                // "running" after the `SIGCONT` lets the entry go.
                processes.resume(pid: entry.pid)
                if processes.isStopped(pid: entry.pid) == false {
                    resumedDropped.append(entry.pid)
                } else {
                    stillUnverified.append(entry)
                    droppedUnproved = true
                }
                continue
            }
            if processes.isStopped(pid: entry.pid) == false {
                resumedDropped.append(entry.pid)
            } else {
                stillUnverified.append(entry)
                droppedUnproved = true
            }
        }
        record.unverified = stillUnverified

        for entry in record.stopped where !names.contains(entry.appName) {
            // An UNPROVABLE identity must not be skipped silently: the app is
            // excluded from the target enumeration below, so nothing else would
            // ever look at it again and it would stay frozen with no notice
            // (gate finding, `Deselected apps silently remain paused after
            // identity read failure`). Raise the attention instead.
            guard identityProved(entry) else {
                droppedUnproved = true
                continue
            }
            if processes.isStopped(pid: entry.pid) == true {
                processes.resume(pid: entry.pid)
            }
            if processes.isStopped(pid: entry.pid) == false {
                resumedDropped.append(entry.pid)
            } else {
                // The resume did not take. The app is no longer a target, so
                // nothing else will ever revisit it: say so rather than
                // reporting a clean success over a frozen app (gate finding,
                // `Échec de reprise d'une application désélectionnée non
                // signalé`).
                droppedUnproved = true
            }
        }
        if droppedUnproved {
            outcome.shouldNotify = true
            outcome.notice = outcome.notice ?? .appsLeftPaused
        }
        if !resumedDropped.isEmpty {
            let dropped = Set(resumedDropped)
            record.stopped.removeAll { dropped.contains($0.pid) }
            outcome.resumedPids = resumedDropped
            outcome.changed = true
            journal.save(record)
        }

        // A FAILED enumeration is not "no matching apps": collapse them and the
        // service reports the pause as applied while the apps keep running
        // (gate finding, `Process enumeration failure becomes successful
        // pause`).
        guard let scan = processes.runningProcesses(matching: names) else {
            return .failure("could not enumerate processes to pause")
        }
        // An INCONCLUSIVE scan (nothing found, something unreadable) may have
        // missed a target: report it rather than claiming a clean result.
        if scan.isInconclusive {
            return .failure("could not read \(scan.unreadable) process(es); "
                + "the pause could not be confirmed")
        }
        let targets = scan.targets
        // A SELECTED unverified entry whose stop has since LANDED is excluded
        // from enumeration (the backend skips stopped processes), so it was
        // never reported even though it is ours and frozen (gate finding,
        // `Selected unverified stops disappear from subsequent outcome
        // reporting`). Say so.
        let selectedUnverified = record.unverified.filter { names.contains($0.appName) }
        if !selectedUnverified.isEmpty {
            outcome.shouldNotify = true
            outcome.notice = outcome.notice ?? .appsLeftPaused
            outcome.unverifiedPids = record.unverified.map { $0.pid }
        }
        let known = Set(record.stopped.map { $0.pid })
        let pending = targets
            .map { $0.journalEntry(bootID: bootID) }
            .filter { entry in
                guard known.contains(entry.pid) else { return true }
                // Already journaled, but that is not proof it is STILL stopped:
                // something else may have resumed it while the lid stayed
                // closed. Re-check and re-stop it, or the service keeps
                // reporting the pause as applied over a running app (gate
                // finding, `Recorded processes are never checked for continued
                // suspension`).
                return processes.isStopped(pid: entry.pid) != true
            }
        guard !pending.isEmpty else {
            // Nothing NEW to stop, but a SELECTED entry may still be sitting in
            // `unverified` from an earlier tick — an obligation the operator was
            // told about. Returning a clean `.stopped` made every subsequent
            // tick claim `.applied` over it (gate finding, `Outstanding
            // unverified stops are reported as successfully applied`).
            let selectedUnverified = record.unverified.filter { names.contains($0.appName) }
            return selectedUnverified.isEmpty ? .success(.stopped) : .success(.unconfirmed)
        }

        var stopped: [LidCloseActionJournal.StoppedProcess] = []
        var failed: [Int32] = []
        var unconfirmedPids: [Int32] = []
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
            // REPLACE any existing entry for this pid: re-stopping a process
            // that was resumed behind our back must not append a second
            // ownership record, which would grow the journal without bound and
            // send duplicate SIGCONTs on undo (gate finding, `Re-stopping a
            // recorded process appends duplicate ownership entries`).
            record.stopped.removeAll { $0.pid == entry.pid }
            record.stopped.append(entry)
            guard journal.save(record) else {
                record.stopped.removeAll { $0.pid == entry.pid }
                return .journalFailed(stoppedSoFar: stopped.map { $0.pid })
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
            // A REJECTED signal (EPERM on another user's process, a process
            // that just exited) is not a pending stop: recording it would keep
            // asking the operator to verify a signal that was never delivered
            // (gate finding, `Rejected stop signals become permanent recovery
            // obligations`).
            guard processes.stop(pid: entry.pid) else {
                failed.append(entry.pid)
                record.stopped.removeAll { $0.pid == entry.pid }
                journal.save(record)
                continue
            }
            // `kill(2)` returning 0 means "delivered", not "stopped", and the
            // transition is not instantaneous: a single immediate read can
            // legitimately still see it running. Deleting the entry on that
            // reading is what orphaned a genuinely-stopped process (gate
            // finding), so the confirmation is RETRIED before it is believed.
            switch confirmStopped(pid: entry.pid) {
            case .some(true):
                stopped.append(entry)
            case .some(false):
                // Still running after the bounded retries. That is NOT proof
                // the signal will never take: `SIGSTOP` is asynchronous and a
                // delivered one can land later, which would leave the app
                // suspended with no entry to recover it (gate finding, `A stop
                // confirmation timeout discards a pending signal's recovery
                // entry`).
                //
                // So the entry moves to `unverified` rather than disappearing:
                // the undo still refuses to `SIGCONT` a process it cannot prove
                // is stopped-or-pending (`SIGCONT` on a running process is a
                // harmless no-op, but the identity rule is what protects us),
                // and the operator is told something needs checking.
                failed.append(entry.pid)
                record.stopped.removeAll { $0.pid == entry.pid }
                // Replace by FULL IDENTITY, not by pid: a recycled pid may
                // already have an entry here for the OLD process, and refusing
                // to add the new one left the newly suspended app with no
                // recovery record at all (gate finding, `PID reuse can discard a
                // new process's recovery entry`).
                if !record.unverified.contains(where: { $0.identity == entry.identity }) {
                    record.unverified.append(entry)
                }
                // Tell the operator NOW. Normal apply ticks do not revisit
                // `unverified` entries, so without this the app could stop a
                // moment later and stay frozen with the promised notice never
                // raised (gate finding, `Stop timeouts leave recovery
                // obligations without operator notification`).
                outcome.changed = true
                outcome.shouldNotify = true
                outcome.notice = outcome.notice ?? .appsLeftPaused
                outcome.unverifiedPids = record.unverified.map { $0.pid }
                // Tell the operator NOW. Normal apply ticks do not revisit
                // `unverified` entries, so without this the app could stop a
                // moment later and stay frozen with the promised notice never
                // raised (gate finding, `Stop timeouts leave recovery
                // obligations without operator notification`).

            case .none:
                // UNREADABLE is not proof of absence: keep the entry so the
                // undo can re-prove and reverse it. The process may genuinely be
                // suspended, so this is a real (if unconfirmed) change and the
                // operator must be told (gate finding, `Unreadable stop
                // confirmation hides an actual suspension`).
                failed.append(entry.pid)
                unconfirmedPids.append(entry.pid)
                outcome.changed = true
                outcome.shouldNotify = true
                outcome.notice = outcome.notice ?? .appsLeftPaused
            }
        }
        outcome.stoppedPids = stopped.map { $0.pid }
        guard failed.isEmpty else {
            // Apps WERE stopped. Reporting a bare failure here said "nothing
            // landed" over a machine that now has frozen processes — the
            // caller and the audit were both misled, and it is the opposite of
            // what the journal says (Lord round 1, point 3).
            guard !stopped.isEmpty else {
                // Nothing CONFIRMED — but if any of those failures was merely
                // UNREADABLE, the app may be suspended, so this is
                // `.unconfirmed`, not `.failed`.
                if !unconfirmedPids.isEmpty && unconfirmedPids.count == failed.count {
                    return .success(.unconfirmed)
                }
                return .failure("could not stop \(failed.count) process(es): \(failed)")
            }
            return .success(.partial)
        }
        return .success(.stopped)
    }

    /// The first stranded device that has COME BACK still muted, removed from
    /// the list. `nil` when none has.
    private mutating func firstReturnedStrandedDevice(
        _ record: inout LidCloseActionJournal.Record
    ) -> LidCloseActionJournal.AudioState? {
        for (index, stranded) in record.unverifiedAudio.enumerated() {
            guard let back = audio.readOutput(uid: stranded.deviceUID) else { continue }
            guard back.isMuted != false else {
                // Back and ALREADY AUDIBLE: nothing of ours is left to restore,
                // so the obligation must go. Keeping it raised operator
                // attention forever over a device whose sound is fine (gate
                // finding, `Already-restored stranded devices never leave
                // recovery`).
                record.unverifiedAudio.remove(at: index)
                journal.save(record)
                return nil
            }
            record.unverifiedAudio.remove(at: index)
            return stranded
        }
        return nil
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

        // A stranded device that has COME BACK is re-adopted here too: with the
        // switch being turned off is exactly when the operator expects the
        // sound back, and the apply path only re-adopts while the switch is on
        // (gate finding, `Disabling audio restoration skips stranded devices`).
        if !decision.muteAudio, let stranded = firstReturnedStrandedDevice(&record) {
            if !record.audio.contains(where: { $0.deviceUID == stranded.deviceUID }) {
                record.audio.append(stranded)
            }
        }
        // PERSIST what the re-adoption just changed. `firstReturnedStrandedDevice`
        // may have RESOLVED a stranded entry (returned and already audible),
        // and without writing that back the caller's later `record = ...`
        // replaced the fresh snapshot with the stale one — restoring state that
        // was already settled (gate finding, `Resolved stranded audio entries
        // are restored from stale state`).
        outcome.evaluation.journalBefore = record

        if !decision.muteAudio, !record.audio.isEmpty {
            var scratch = TickOutcome(evaluation: evaluation)
            unmuteRecordedDevice(journal: &record, into: &scratch)
            if scratch.audioDeviceGone { outcome.audioDeviceGone = true }
            if scratch.changed { outcome.changed = true }
            // CARRY the failure report, not just `changed`. A PARTIAL restore
            // (one device back, one not) set both on `scratch`, and dropping
            // them here — while the fallback below only fires when nothing
            // changed — left the operator with no notice over a device still
            // muted (gate finding, `Partial audio restoration suppresses the
            // failure notice`).
            if scratch.audioRestoreFailed {
                outcome.shouldNotify = true
                outcome.notice = outcome.notice ?? .audioLeftMuted
                outcome.audioRestoreFailed = true
            }
            // CARRY the failure report, not just `changed`. A PARTIAL restore
            // (one device back, one not) set both on `scratch`, and dropping
            // them here — while the fallback below only fires when nothing
            // changed — left the operator with no notice over a device still
            // muted (gate finding, `Partial audio restoration suppresses the
            // failure notice`).

            // CARRY the failure report, not just `changed`. A PARTIAL restore
            // (one device back, one not) set both on `scratch`, and dropping
            // them here — while the fallback below only fires when nothing
            // changed — left the operator with no notice over a device still
            // muted (gate finding, `Partial audio restoration suppresses the
            // failure notice`).

            // A restore that did NOT land must be visible: the entry is kept
            // for a retry (correct), but reporting `.nothingRequested` or a
            // plain success would tell the operator the sound is back when it
            // is not (gate finding, `L'échec de restauration audio reste
            // silencieux`).
            if !record.audio.isEmpty && !scratch.changed {
                outcome.shouldNotify = true
                outcome.notice = outcome.notice ?? .audioLeftMuted
                outcome.audioRestoreFailed = true
            }
            outcome.evaluation.journalBefore = record
        }
        // Turning the audio switch off must STILL report a device that is
        // stranded in `unverifiedAudio`: with no `record.audio` the branch above
        // is skipped entirely, so the obligation went silent forever (gate
        // finding, `Disabling audio suppresses stranded-device alerts`).
        if !decision.muteAudio, record.audio.isEmpty, !record.unverifiedAudio.isEmpty {
            outcome.shouldNotify = true
            outcome.notice = outcome.notice ?? .audioLeftMuted
            outcome.audioRestoreFailed = true
        }

        if !decision.pauseApps, !record.stopped.isEmpty || !record.unverified.isEmpty {
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
        // PERSIST the outcome. A resume removes entries in memory; returning
        // without saving left ownership of a resumed process on disk, and a
        // later undo could then `SIGCONT` a process the operator had paused
        // themselves (gate finding, `Disabling both effects can leave resumed
        // processes owned on disk`).
        if outcome.changed {
            // A save that does not land leaves stale ownership on disk, which a
            // later undo could act on — reversing something the operator did
            // (gate finding, `Failed persistence after resume leaves stale
            // signal authority`). Reported, never swallowed.
            if !journal.save(record) { outcome.journalSaveFailed = true }
            outcome.apply = outcome.apply ?? .applied
        }

        // Any reversal is an effect, not "nothing requested".
    }

    /// Is the mute this journal entry claims actually in effect right now?
    ///
    /// `alreadyMuted` when the device reads muted; `muted` after a retry that
    /// lands; `failed` when it reads audible or cannot be read, so the caller
    /// never reports a silent Mac that is not silent.
    private func confirmExistingMute(
        record: LidCloseActionJournal.Record
    ) -> AudioEffect {
        // The CURRENT default output, not `audio.first`: with more than one
        // recorded device, checking the first one let the service report the
        // mute applied while the device actually in use stayed audible (Lord
        // review round 4, follow-up).
        // The CURRENT default output, not `audio.first`: with more than one
        // recorded device, checking the first one let the service report the
        // mute applied while the device actually in use stayed audible (Lord
        // review round 4, follow-up).
        let currentUID = audio.readDefaultOutput()?.uid
        guard let entry = record.audio.first(where: { $0.deviceUID == currentUID })
                ?? record.audio.first else { return .alreadyMuted }
        guard let snapshot = audio.readOutput(uid: entry.deviceUID),
              let muted = snapshot.isMuted else {
            return .failed
        }
        guard muted else {
            // Still audible: retry the write once, then believe only a readback.
            guard snapshot.canMute else { return .failed }
            audio.setMuted(true, uid: entry.deviceUID)
            // Three-way, exactly like the initial mute: an ACCEPTED write whose
            // readback is unavailable may well have muted the device, so
            // reporting `.failed` ("nothing landed") contradicted the machine
            // (gate finding, `Mute retry loses an accepted but unconfirmed
            // change`).
            switch audio.readOutput(uid: entry.deviceUID)?.isMuted {
            case .some(true): return .muted
            case .some(false): return .failed
            case .none: return .unconfirmed
            }
        }
        return .alreadyMuted
    }

    private enum AudioEffect: String, Sendable {
        case muted
        case alreadyMuted
        case alreadyRecorded
        /// The write was ACCEPTED but the readback was unavailable. The machine
        /// may well have changed, so this counts as a change while still being
        /// reported as unverified (gate finding, `An actual mute can be reported
        /// as no machine change`).
        case unconfirmed
        case failed
        case skipped
    }

    private enum AppsEffect: String, Sendable {
        /// Every target was stopped and confirmed.
        case stopped
        /// SOME were stopped and confirmed, some were not. Distinct from
        /// `failed` because apps ARE frozen: the undo must still run for them,
        /// and the caller must not be told nothing happened (Lord round 1,
        /// point 3).
        case partial
        /// The signals were ACCEPTED but the stopped state could not be read.
        /// The app may well be suspended, so this is NOT `.failed` — that
        /// promises nothing landed (gate finding, `Unconfirmed process stops are
        /// classified as no effect`).
        case unconfirmed
        case failed
        case skipped
    }

    /// Combine the two effects into one word for the caller and the audit.
    private func combine(audio: AudioEffect, apps: AppsEffect) -> ApplyOutcome {
        let audioOK = audio == .muted || audio == .alreadyMuted || audio == .alreadyRecorded
        let appsOK = apps == .stopped
        // `partial` means SOMETHING landed for that effect, so it is not a
        // failure — but it is not a clean success either. An UNCONFIRMED audio
        // write is the same shape: the write was accepted, so the machine may
        // be muted; reporting `.failed` ("nothing landed") contradicts
        // `changed == true` (gate finding, `An unconfirmed mute is classified
        // as no effect`).
        let appsPartial = apps == .partial || apps == .unconfirmed
        let audioUnconfirmed = audio == .unconfirmed
        let audioAsked = audio != .skipped
        let appsAsked = apps != .skipped
        let asked = [audioAsked, appsAsked].filter { $0 }.count
        let ok = [audioAsked && audioOK, appsAsked && appsOK].filter { $0 }.count
        if asked == 0 { return .nothingRequested }
        if ok == asked { return .applied }
        // Anything landed at all (including a partial effect) is `.partial`,
        // never `.failed`: `.failed` promises the machine is untouched, and
        // the undo's decision to run hangs off that promise.
        if ok > 0 || appsPartial || audioUnconfirmed { return .partial }
        return .failed
    }

    /// Three-way result for one effect: done, refused with a reason, or the
    /// journal could not record it (which makes the effect illegal, because it
    /// could not be undone).
    private enum EffectResult<T> {
        case success(T)
        case failure(String)
        /// The journal could not record the effect. Carries what had ALREADY
        /// landed, so a partial result is never reported as nothing happened.
        case journalFailed(stoppedSoFar: [Int32] = [])
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
                || !record.unverifiedAudio.isEmpty else {
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
        var remaining: [LidCloseActionJournal.StoppedProcess] = []
        var resumed: [Int32] = []
        var unverified: [LidCloseActionJournal.StoppedProcess] = []

        // Retry the ones an earlier pass gave up on, but ONLY those whose
        // identity is provable now: a bounded stop-confirmation window is not
        // proof a pending `SIGSTOP` will never take, and opening the lid must
        // still be able to resume an app that stopped a moment too late
        // (gate finding, `Un SIGSTOP retardé perd sa récupération
        // automatique`). This runs BEFORE the `stopped` guard, because a record
        // holding only `unverified` entries is exactly the case it exists for.
        var stillUnknown: [LidCloseActionJournal.StoppedProcess] = []
        for entry in record.unverified {
            guard identityProved(entry) else { stillUnknown.append(entry); continue }
            // Reads RUNNING. Two very different worlds produce that reading: an
            // external SIGCONT genuinely released it, or our SIGSTOP is still
            // IN FLIGHT. Sending `SIGCONT` disambiguates — it is a no-op on a
            // running process and it CANCELS a pending stop — so only a
            // positive "running" AFTER it settles the obligation. Both findings
            // hold: a healthy app leaves recovery, and a pending signal is
            // never silently dropped.
            processes.resume(pid: entry.pid)
            if processes.isStopped(pid: entry.pid) == false {
                resumed.append(entry.pid)
                continue
            }
            // Only a POSITIVE "stopped" is a reason to signal. An unreadable
            // state is not proof the process is running, so the entry stays
            // (gate finding, `Unreadable process state drops its recovery
            // entry`).
            switch processes.isStopped(pid: entry.pid) {
            case .some(true):
                break
            case .some(false):
                // Reads as running. That does NOT mean nothing of ours is
                // holding it: a delivered `SIGSTOP` can still be pending (that
                // is exactly how the entry got here), and dropping it would let
                // the signal land afterwards with no recovery left (gate
                // finding, `Undo discards recovery for a still-pending
                // SIGSTOP`). Keep it listed as to-verify rather than erasing it.
                stillUnknown.append(entry)
                continue
            case .none:
                stillUnknown.append(entry)
                continue
            }
            processes.resume(pid: entry.pid)
            if processes.isStopped(pid: entry.pid) == false {
                resumed.append(entry.pid)
            } else {
                stillUnknown.append(entry)
            }
        }
        record.unverified = stillUnknown
        if !resumed.isEmpty { outcome.changed = true; outcome.resumedPids = resumed }
        if !stillUnknown.isEmpty {
            outcome.shouldNotify = true
            outcome.notice = .appsLeftPaused
            outcome.unverifiedPids = stillUnknown.map { $0.pid }
        }

        // Nothing NEW to resume, but an obligation carried from an earlier pass
        // still has to be reported. Returning here silenced the notice on the
        // second pass, when `stopped` was already empty and only `unverified`
        // remained (gate finding, `Persisted unverified processes stop raising
        // attention`).
        guard !record.stopped.isEmpty else {
            // Process obligations only. A stranded AUDIO device is reported by
            // the audio step, which runs AFTER this one: raising it here meant a
            // device that the audio step then restored still produced a notice
            // (gate finding, `Already-restored stranded devices never leave
            // recovery`).
            if !record.unverified.isEmpty {
                outcome.unverifiedPids = record.unverified.map { $0.pid }
                outcome.shouldNotify = true
                outcome.notice = .appsLeftPaused
            }
            return
        }
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
        // dropped by the next apply. De-duplicated by FULL IDENTITY, not pid:
        // a recycled pid belongs to a different process and must be able to
        // carry its own recovery entry.
        for entry in unverified
        where !record.unverified.contains(where: { $0.identity == entry.identity }) {
            record.unverified.append(entry)
        }
        if !journal.save(record) { outcome.journalSaveFailed = true }

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
        // A device concluded gone that has COME BACK still muted: re-adopt it
        // here, not only in `apply`. A session can end (or the master switch be
        // turned off) while the device is unplugged, and its return must still
        // be restorable — otherwise it stays muted indefinitely.
        if let stranded = firstReturnedStrandedDevice(&record) {
            if !record.audio.contains(where: { $0.deviceUID == stranded.deviceUID }) {
                record.audio.append(stranded)
            }
            journal.save(record)
        }
        guard !record.audio.isEmpty else {
            // Nothing left in `audio`, but a STRANDED device may still be
            // recorded: it stopped triggering any alert and the operator was
            // never told (gate finding, `Les périphériques audio devenus
            // injoignables cessent de déclencher une alerte`).
            if !record.unverifiedAudio.isEmpty {
                outcome.shouldNotify = true
                outcome.notice = .audioLeftMuted
                outcome.audioRestoreFailed = true
            }
            return
        }

        // EVERY recorded device, not just the first: the default output can
        // change during a session, so there can be more than one device of ours
        // to restore (Lord review round 4).
        var failedThisPass: [String] = []
        for prior in record.audio {
            if case .retry = unmuteOne(prior, journal: &record, into: &outcome) {
                failedThisPass.append(prior.deviceUID)
            }
        }
        guard !failedThisPass.isEmpty else { return }
        outcome.shouldNotify = true
        outcome.notice = .audioLeftMuted
        outcome.audioRestoreFailed = true
    }

    /// Restore ONE recorded device. Returns `.retry` when the entry must stay.
    private mutating func unmuteOne(
        _ priorStored: LidCloseActionJournal.AudioState,
        journal record: inout LidCloseActionJournal.Record,
        into outcome: inout TickOutcome
    ) -> UnmuteResult {
        var prior = priorStored

        // A SUCCESSFUL read resets the consecutive-unreadable counter.
        //
        // Without this the counter only ever grew: a cable that flapped 200
        // times one evening, then a perfectly healthy device for hours, would
        // still be sitting at 200 — and 160 unrelated failures later the
        // threshold would conclude "gone" long after continuity was broken. The
        // threshold must mean CONSECUTIVE passes (Lord review, round 3).
        let readable = readOutputTwice(uid: prior.deviceUID)
        if readable != nil, prior.unreadablePasses != 0 {
            prior.unreadablePasses = 0
            replaceAudio(prior, in: &record)
            journal.save(record)
        }

        guard let current = readable else {
            // Still unreadable after the retry. NOT proof of removal: the entry
            // stays and counts up, and "gone" is only concluded after several
            // SEPARATE passes.
            prior.unreadablePasses += 1
            if prior.unreadablePasses >= Self.unreadablePassesBeforeGone {
                // Concluding "gone" must not FORGET the device: it can come
                // back. The obligation moves to `unverifiedAudio` instead.
                removeAudio(prior.deviceUID, in: &record)
                if !record.unverifiedAudio.contains(where: { $0.deviceUID == prior.deviceUID }) {
                    record.unverifiedAudio.append(prior)
                }
                journal.save(record)
                outcome.audioDeviceGone = true
                writeAudit(outcome: "deviceGone", reason: "undo",
                           evaluation: outcome.evaluation, audio: "gone",
                           audioError: "unreadable on \(prior.unreadablePasses) separate passes; kept as unverified",
                           audioDeviceUID: prior.deviceUID, stopped: [], failed: [], error: nil)
                return .done
            }
            replaceAudio(prior, in: &record)
            journal.save(record)
            writeAudit(outcome: "partial", reason: "undo", evaluation: outcome.evaluation,
                       audio: "readUnavailable",
                       audioError: "the device could not be read; the restore is unconfirmed",
                       audioDeviceUID: prior.deviceUID, stopped: [], failed: [], error: nil)
            return .retry
        }

        guard !prior.wasMuted else {
            // Silent before we arrived: leave it silent.
            removeAudio(prior.deviceUID, in: &record)
            outcome.changed = true
            journal.save(record)
            writeAudit(outcome: "undone", reason: "undo", evaluation: outcome.evaluation,
                       audio: "leftMuted", audioError: nil, audioDeviceUID: prior.deviceUID,
                       stopped: [], failed: [], error: nil)
            return .done
        }

        // Only a POSITIVE "audible" proves someone else already did our job. An
        // unreadable flag is not that proof, so we fall through and write.
        if current.isMuted == false {
            removeAudio(prior.deviceUID, in: &record)
            outcome.changed = true
            journal.save(record)
            writeAudit(outcome: "undone", reason: "undo", evaluation: outcome.evaluation,
                       audio: "alreadyAudible", audioError: nil,
                       audioDeviceUID: prior.deviceUID, stopped: [], failed: [], error: nil)
            return .done
        }

        audio.setMuted(false, uid: prior.deviceUID)
        // Readback, not acceptance: only a device that reads audible is
        // restored (ADR 009).
        guard audio.readOutput(uid: prior.deviceUID)?.isMuted == false else {
            writeAudit(outcome: "partial", reason: "undo", evaluation: outcome.evaluation,
                       audio: "unmuteFailed",
                       audioError: "readback did not confirm the unmute",
                       audioDeviceUID: prior.deviceUID, stopped: [], failed: [], error: nil)
            return .retry
        }
        removeAudio(prior.deviceUID, in: &record)
        journal.save(record)
        outcome.changed = true
        writeAudit(outcome: "undone", reason: "undo", evaluation: outcome.evaluation,
                   audio: "unmuted", audioError: nil, audioDeviceUID: prior.deviceUID,
                   stopped: [], failed: [], error: nil)
        return .done
    }

    private enum UnmuteResult { case done, retry }

    private func replaceAudio(_ state: LidCloseActionJournal.AudioState,
                              in record: inout LidCloseActionJournal.Record) {
        guard let i = record.audio.firstIndex(where: { $0.deviceUID == state.deviceUID })
        else { return }
        record.audio[i] = state
    }

    private func removeAudio(_ uid: String,
                             in record: inout LidCloseActionJournal.Record) {
        record.audio.removeAll { $0.deviceUID == uid }
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
            && record.unverifiedAudio.isEmpty {
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
