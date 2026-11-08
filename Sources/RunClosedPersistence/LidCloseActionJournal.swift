import Foundation
import RunClosedCore

/// The journal of everything the lid-close actions changed (ADR 026).
///
/// One file, `lid_close_actions.json`, in the same Application Support
/// directory as the other stores. It is written **BEFORE** every change and
/// cleared only after a readback-verified undo (ADR 009), exactly like
/// `OwnedLidAssertion`:
///
/// - an entry that exists means "RunClosed may have done this", so the undo
///   knows what to reverse after a crash;
/// - an entry that is gone means "a readback proved the previous state is
///   back".
///
/// The record is deliberately a LIST of effects rather than a set of booleans:
/// which audio device was muted and what its prior state was, and which
/// processes were stopped with the three values that make a pid an identity.
public struct LidCloseActionJournal: Sendable {
    public let url: URL

    /// Canonical path: `~/Library/Application Support/RunClosed/lid_close_actions.json`.
    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunClosed", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("lid_close_actions.json")
    }

    /// Test seam: explicit URL.
    public init(url: URL) {
        self.url = url
    }

    /// One element decoded without failing the whole array.
    private struct LooseAudioState: Decodable {
        let state: AudioState?
        init(from decoder: Decoder) throws {
            state = try? AudioState(from: decoder)
        }
    }


    /// The prior audio state of the device we muted.
    ///
    /// The DEVICE is recorded by UID, not by `AudioObjectID`: the id is a
    /// per-process handle that changes across restarts and device re-plugs,
    /// while the UID names the same physical output. Recording the id would
    /// make the undo unable to find the device it muted.
    public struct AudioState: Codable, Equatable, Sendable {
        /// `kAudioDevicePropertyDeviceUID` of the device we muted.
        public var deviceUID: String
        /// Whether the device was already muted before we touched it. `true`
        /// means we have nothing to un-mute: the operator had it silent.
        public var wasMuted: Bool
        /// The output volume scalar before we touched it, when the device
        /// reports one. `nil` = the device has no settable volume, so only the
        /// mute flag belongs to us.
        public var volume: Float?
        /// Consecutive undo passes that could not READ this device.
        ///
        /// One unreadable read is not proof of removal, so the entry stays and
        /// this counts up. Only a device that stays unreadable across several
        /// separate passes is concluded gone — otherwise a flaky read would
        /// strand the obligation, and concluding removal on the first failure
        /// would leave a muted Mac with nothing to retry from.
        public var unreadablePasses: Int

        public init(deviceUID: String, wasMuted: Bool, volume: Float?,
                    unreadablePasses: Int = 0) {
            self.deviceUID = deviceUID
            self.wasMuted = wasMuted
            self.volume = volume
            self.unreadablePasses = unreadablePasses
        }

        private enum CodingKeys: String, CodingKey {
            case deviceUID, wasMuted, volume, unreadablePasses
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            deviceUID = try c.decode(String.self, forKey: .deviceUID)
            wasMuted = try c.decodeIfPresent(Bool.self, forKey: .wasMuted) ?? false
            volume = try c.decodeIfPresent(Float.self, forKey: .volume)
            unreadablePasses = try c.decodeIfPresent(Int.self, forKey: .unreadablePasses) ?? 0
        }
    }

    /// One stopped process, identified by the three values that make a pid
    /// mean something. A pid alone is recycled by the kernel, so "pid 4711 is
    /// stopped" is not a fact that survives even a few minutes.
    public struct StoppedProcess: Codable, Equatable, Sendable {
        public var pid: Int32
        /// `pbi_start_tvsec` — the process start time, in seconds since the
        /// epoch.
        public var startSeconds: UInt64
        /// `pbi_start_tvusec` — the microsecond part of the same instant.
        public var startMicroseconds: UInt64
        /// `kern.bootsessionuuid` of the boot that recorded this. A start time
        /// is only comparable within one boot session.
        public var bootID: String
        /// The executable path, for the operator's benefit and for the log.
        public var path: String
        /// The app name this process belongs to (`Slack`, `Discord`…).
        public var appName: String

        public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64,
                    bootID: String, path: String, appName: String) {
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
            self.bootID = bootID
            self.path = path
            self.appName = appName
        }

        /// The identity triple, as one comparable value.
        public var identity: ProcessIdentity {
            ProcessIdentity(pid: pid, startSeconds: startSeconds,
                            startMicroseconds: startMicroseconds, bootID: bootID)
        }
    }

    /// A process identity that survives pid recycling (ADR 026).
    public struct ProcessIdentity: Codable, Equatable, Sendable {
        public var pid: Int32
        public var startSeconds: UInt64
        public var startMicroseconds: UInt64
        public var bootID: String

        public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64, bootID: String) {
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
            self.bootID = bootID
        }
    }

    public struct Record: Codable, Equatable, Sendable {
        public var schemaVersion: Int = kLidCloseActionSchemaVersion
        /// The session the actions belong to. `nil` when the journal was
        /// written without one (never in practice, but a corrupt-but-decodable
        /// file must not make the undo unreachable).
        public var sessionID: UUID?
        /// ISO-8601 instant the journal was opened.
        public var startedAt: String?
        /// The audio effects: one entry per device we muted.
        ///
        /// A LIST, not a single slot, because the default output can CHANGE
        /// during a session. Muting only the first device left a second output
        /// (headphones plugged in mid-session) audible while the service
        /// reported the action applied (Lord review round 4).
        public var audio: [AudioState]
        /// The processes we stopped. Empty when the app-pause switch is off.
        public var stopped: [StoppedProcess]
        /// Processes whose identity could not be re-proved at undo time: they
        /// were left alone on purpose and are reported as "to verify" rather
        /// than resumed blindly (ADR 026).
        ///
        /// This is a REPORT, written by the undo; it is not a claim of
        /// ownership, so it never itself authorises a `SIGCONT`.
        public var unverified: [StoppedProcess]
        /// Audio devices this service muted that became unreachable and were
        /// concluded gone. A LIST: several outputs can be muted across a session
        /// (the default output changes), and a single slot made the second one
        /// overwrite the first device's record (gate finding, `A second missing
        /// device overwrites the first device's recovery record`).
        ///
        /// Kept rather than discarded because a device can RETURN: headphones
        /// unplugged and plugged back in still hold their mute state. Moving
        /// the obligation here stops it driving the undo (nothing to reach) while
        /// keeping it visible to the operator and re-adoptable by a later apply
        /// (gate finding, `Temporary device absence permanently discards
        /// restoration`).
        public var unverifiedAudio: [AudioState]
        /// How many audio entries were discarded because a field was malformed.
        /// Not persisted; set by the decoder so a damaged journal is visible.
        public var droppedAudioEntries: Int = 0

        /// A record that decoded BUT lost entries to malformed fields.
        ///
        /// `LooseAudioState` keeps one bad element from discarding the others,
        /// but a dropped element is a lost obligation: the device may still be
        /// muted with nothing authorising its restore. This makes the damage
        /// visible instead of claiming a healthy journal (gate finding,
        /// `Tolerant decoding silently loses audio restoration records`).
        public var hasDroppedAudioEntries: Bool { droppedAudioEntries > 0 }

        public init(schemaVersion: Int = kLidCloseActionSchemaVersion,
                    sessionID: UUID? = nil,
                    startedAt: String? = nil,
                    audio: [AudioState] = [],
                    stopped: [StoppedProcess] = [],
                    unverified: [StoppedProcess] = [],
                    unverifiedAudio: [AudioState] = []) {
            self.schemaVersion = schemaVersion
            self.sessionID = sessionID
            self.startedAt = startedAt
            self.audio = audio
            self.stopped = stopped
            self.unverified = unverified
            self.unverifiedAudio = unverifiedAudio
        }

        /// Nothing of ours is OUTSTANDING as a live effect. The predicate the
        /// policy consumes as `currentlyApplied` also counts the obligations
        /// (`unverified`, `unverifiedAudio`), because an operator still waiting
        /// on an answer is not "nothing to report".
        public var isEmpty: Bool { audio.isEmpty && stopped.isEmpty }

        /// The record a fresh apply starts from. `unverified` is carried over
        /// deliberately: a process we could not prove is still something the
        /// operator has to be told about, so a new episode must not erase it
        /// before it was reported.
        public func reopened(sessionID: UUID?, at instant: String) -> Record {
            Record(sessionID: sessionID, startedAt: instant,
                   audio: audio, stopped: stopped, unverified: unverified,
                   // `unverifiedAudio` is an OBLIGATION, and reopening must not
                   // drop it: a device concluded gone whose return has not been
                   // dealt with yet would otherwise be forgotten the moment a
                   // new session starts (gate finding, `reopened efface
                   // unverifiedAudio`).
                   unverifiedAudio: unverifiedAudio)
        }

        /// Tolerant decoding: a key added by a later version must not make an
        /// existing journal read as empty, which would lose the undo.
        private enum CodingKeys: String, CodingKey {
            case schemaVersion, sessionID, startedAt, audio, stopped, unverified,
                 unverifiedAudio
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? kLidCloseActionSchemaVersion
            sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
            startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
            // Decoded ENTRY BY ENTRY: one malformed element must not discard
            // every other device's recovery record. A whole-array `try?` made a
            // single bad field flatten the list to `[]` while the record still
            // decoded, so `isCorrupt` said "readable" over devices left muted
            // (Lord review round 4, follow-up).
            if let loose = try? c.decode([LooseAudioState].self, forKey: .audio) {
                audio = loose.compactMap { $0.state }
                droppedAudioEntries = loose.filter { $0.state == nil }.count
            } else if let one = try? c.decode(AudioState.self, forKey: .audio) {
                audio = [one]
            } else {
                // NEITHER shape decoded: the field is PRESENT but malformed as a
                // whole (e.g. `"audio": {"deviceUID": 17}`). That is a lost
                // obligation, not an empty list — counting it keeps `isCorrupt`
                // honest (gate finding, `Malformed audio fields bypass
                // corruption reporting`).
                audio = []
                if (try? c.contains(.audio)) == true { droppedAudioEntries += 1 }
            }
            // Same for the obligation list — but an ARRAY failure alone is not
            // damage: the legacy SINGULAR form is supported, and counting it as
            // corrupt made `lid-close status` exit 3 over a perfectly good
            // journal written by the earlier build (gate finding, `Supported
            // legacy audio records trigger false corruption reports`).
            if (try? c.contains(.unverifiedAudio)) == true,
               (try? c.decode([AudioState].self, forKey: .unverifiedAudio)) == nil,
               (try? c.decode(AudioState.self, forKey: .unverifiedAudio)) == nil {
                droppedAudioEntries += 1
            }
            // A damaged element is surfaced, never silently dropped.
            if audio.isEmpty, (try? c.contains(.audio)) == true {
                // Leave `audio` empty; `isCorrupt` is decided by the record
                // decoder, and the CLI reports the journal as unreadable.
            }
            stopped = try c.decodeIfPresent([StoppedProcess].self, forKey: .stopped) ?? []
            unverified = try c.decodeIfPresent([StoppedProcess].self, forKey: .unverified) ?? []
            // Tolerant of the SINGULAR form an earlier build wrote: a file from
            // before this field became a list must not fail to decode.
            if let list = try? c.decode([AudioState].self, forKey: .unverifiedAudio) {
                unverifiedAudio = list
            } else if let one = try? c.decode(AudioState.self, forKey: .unverifiedAudio) {
                unverifiedAudio = [one]
            } else {
                unverifiedAudio = []
            }
        }
    }

    /// Load the journal VERBATIM. A missing or corrupt file reads as an EMPTY
    /// record — which is the safe side only because the caller treats "empty"
    /// as "nothing of ours to undo", and because the alternative (refusing
    /// every read) would leave a muted Mac muted forever.
    ///
    /// The cost is explicit: a journal destroyed by disk corruption means a
    /// process we stopped stays stopped until the operator notices. That is why
    /// the undo never depends on this file being the ONLY memory — the app and
    /// the backstop both run it at every opportunity while the file exists, and
    /// a stopped app is visible in `ps`.
    public func load() -> Record { load(readingFailed: nil) }

    /// Load, reporting whether the file existed but could not be READ.
    ///
    /// A missing file and an unreadable one both produce the empty record, so
    /// every caller would read "nothing of ours to undo". For a MISSING file
    /// that is the truth; for a truncated or temporarily unreadable one it is
    /// the opposite of the truth — the obligation is still there on disk and
    /// the operator is told all is well (gate finding, `Unreadable journal is
    /// indistinguishable from no pending recovery`).
    public func load(readingFailed: (() -> Void)?) -> Record {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard let data = try? Data(contentsOf: url) else {
            if exists { readingFailed?() }
            return Record()
        }
        guard let rec = try? JSONDecoder().decode(Record.self, from: data) else {
            readingFailed?()
            return Record()
        }
        if rec.hasDroppedAudioEntries { readingFailed?() }
        return rec
    }

    /// Whether the file exists but does not decode. Used by `lid-close status`
    /// so a damaged journal is never presented as a clean slate.
    public var isCorrupt: Bool {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard let rec = try? JSONDecoder().decode(Record.self, from: data) else { return true }
        // A record that decoded but LOST an audio entry is damaged too: the
        // obligation is gone from the file even though the JSON still parses.
        return rec.hasDroppedAudioEntries
    }

    /// Atomic write. `.atomic` writes a sibling temp file then renames it into
    /// place — same discipline as `OwnedLidAssertion` and `SessionStore`.
    ///
    /// Returns whether it landed, for the same reason `ThermalLatchStore.save`
    /// does: an action journal that cannot be written must not be acted on,
    /// because the undo would have no record of what to reverse.
    @discardableResult
    public func save(_ record: Record) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Clear the journal after a verified undo (ADR 009: the recovery state is
    /// removed only once a readback confirmed the previous state is back).
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

public let kLidCloseActionSchemaVersion = 1
