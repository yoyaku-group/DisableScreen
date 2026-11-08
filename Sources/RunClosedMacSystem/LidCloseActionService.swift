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
        return Evaluation(
            input: input,
            decision: LidCloseActionPolicy.decide(input, currentlyApplied: !record.isEmpty),
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
        guard !record.isEmpty else {
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
        guard decision.muteAudio || decision.pauseApps else {
            outcome.apply = .nothingRequested
            return
        }

        var record = evaluation.journalBefore
        record.sessionID = currentSessionIdentity
        record.startedAt = ISO8601DateFormatter().string(from: wallClock())

        var audioEffect = AudioEffect.skipped
        var audioError: String?
        var appsEffect = AppsEffect.skipped
        var appError: String?

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
        guard !snapshot.isMuted else { return .success(.alreadyMuted) }

        record.audio = LidCloseActionJournal.AudioState(
            deviceUID: snapshot.uid, wasMuted: false, volume: snapshot.volume)
        guard journal.save(record) else {
            record.audio = nil
            return .journalFailed
        }
        audio.setMuted(true, uid: snapshot.uid)
        // Acceptance is not proof (ADR 009): read back before claiming it.
        guard let after = audio.readOutput(uid: snapshot.uid), after.isMuted else {
            // Nothing changed, so the entry goes: keeping it would un-mute a
            // device we never muted.
            record.audio = nil
            journal.save(record)
            return .failure("readback did not confirm the mute")
        }
        return .success(.muted)
    }

    /// `SIGSTOP` every process matching `names`, journaling the identity TRIPLE
    /// of each one before the signal.
    private mutating func stopMatchingApps(
        names: [String],
        journal record: inout LidCloseActionJournal.Record,
        into outcome: inout TickOutcome
    ) -> EffectResult<AppsEffect> {
        let targets = processes.runningProcesses(matching: names)
        // Journal the WHOLE target set before signalling any of them: a crash
        // mid-loop must still leave the identities of the ones already stopped.
        let known = Set(record.stopped.map { $0.pid })
        let pending = targets
            .map { $0.journalEntry(bootID: bootID) }
            .filter { !known.contains($0.pid) }
        guard !pending.isEmpty else { return .success(.stopped) }
        record.stopped.append(contentsOf: pending)
        guard journal.save(record) else {
            record.stopped.removeAll { entry in pending.contains { $0.pid == entry.pid } }
            return .journalFailed
        }

        var stopped: [LidCloseActionJournal.StoppedProcess] = []
        var failed: [Int32] = []
        for entry in pending {
            processes.stop(pid: entry.pid)
            // `kill(2)` returning 0 means "delivered", not "stopped".
            if processes.isStopped(pid: entry.pid) == true {
                stopped.append(entry)
            } else {
                // Not proved stopped: the journal must not claim it, or the
                // undo would `SIGCONT` a process we never paused — which would
                // resume an app the operator had suspended themselves.
                failed.append(entry.pid)
                record.stopped.removeAll { $0.pid == entry.pid }
            }
        }
        outcome.stoppedPids = stopped.map { $0.pid }
        guard failed.isEmpty else {
            return .failure("could not stop \(failed.count) process(es): \(failed)")
        }
        return .success(.stopped)
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
        guard !record.isEmpty else {
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
        guard !record.stopped.isEmpty else { return }
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
        // dropped by the next apply.
        record.unverified.append(contentsOf: unverified)
        journal.save(record)

        outcome.resumedPids = resumed
        outcome.unverifiedPids = unverified.map { $0.pid }
        if !resumed.isEmpty { outcome.changed = true }
        if !unverified.isEmpty || !remaining.isEmpty {
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
        guard let current = audio.readOutput(uid: prior.deviceUID) else {
            record.audio = nil
            journal.save(record)
            outcome.audioDeviceGone = true
            writeAudit(outcome: "deviceGone", reason: "undo", evaluation: outcome.evaluation,
                       audio: "gone", audioError: nil, audioDeviceUID: prior.deviceUID,
                       stopped: [], failed: [], error: nil)
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
        guard current.isMuted else {
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
        guard let after = audio.readOutput(uid: prior.deviceUID), !after.isMuted else {
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
        if record.isEmpty && record.unverified.isEmpty && !appsStuck {
            journal.clear()
            return .restored
        }
        journal.save(record)
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
