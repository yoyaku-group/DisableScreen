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
        /// The audio effect, when we muted something.
        public var audio: AudioState?
        /// The processes we stopped. Empty when the app-pause switch is off.
        public var stopped: [StoppedProcess]
        /// Processes whose identity could not be re-proved at undo time: they
        /// were left alone on purpose and are reported as "to verify" rather
        /// than resumed blindly (ADR 026).
        ///
        /// This is a REPORT, written by the undo; it is not a claim of
        /// ownership, so it never itself authorises a `SIGCONT`.
        public var unverified: [StoppedProcess]
        /// An audio device this service muted that became unreachable and was
        /// concluded gone.
        ///
        /// Kept rather than discarded because a device can RETURN: headphones
        /// unplugged and plugged back in still hold their mute state. Moving
        /// the obligation here stops it driving the undo (nothing to reach) while
        /// keeping it visible to the operator and re-adoptable by a later apply
        /// (gate finding, `Temporary device absence permanently discards
        /// restoration`).
        public var unverifiedAudio: AudioState?

        public init(schemaVersion: Int = kLidCloseActionSchemaVersion,
                    sessionID: UUID? = nil,
                    startedAt: String? = nil,
                    audio: AudioState? = nil,
                    stopped: [StoppedProcess] = [],
                    unverified: [StoppedProcess] = [],
                    unverifiedAudio: AudioState? = nil) {
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
        public var isEmpty: Bool { audio == nil && stopped.isEmpty }

        /// The record a fresh apply starts from. `unverified` is carried over
        /// deliberately: a process we could not prove is still something the
        /// operator has to be told about, so a new episode must not erase it
        /// before it was reported.
        public func reopened(sessionID: UUID?, at instant: String) -> Record {
            Record(sessionID: sessionID, startedAt: instant,
                   audio: audio, stopped: stopped, unverified: unverified)
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
            audio = try c.decodeIfPresent(AudioState.self, forKey: .audio)
            stopped = try c.decodeIfPresent([StoppedProcess].self, forKey: .stopped) ?? []
            unverified = try c.decodeIfPresent([StoppedProcess].self, forKey: .unverified) ?? []
            unverifiedAudio = try c.decodeIfPresent(AudioState.self, forKey: .unverifiedAudio)
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
    public func load() -> Record {
        guard let data = try? Data(contentsOf: url) else { return Record() }
        guard let rec = try? JSONDecoder().decode(Record.self, from: data) else { return Record() }
        return rec
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
