import XCTest
@testable import RunClosedCore
@testable import RunClosedPersistence

/// The lid-close action journal (ADR 026): the record that makes the undo
/// possible after a crash, so its failure modes are load-bearing.
final class LidCloseActionJournalTests: XCTestCase {

    private func makeJournal() -> (LidCloseActionJournal, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-journal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lid_close_actions.json")
        return (LidCloseActionJournal(url: url), url)
    }

    func testRoundTrip() {
        let (journal, _) = makeJournal()
        let record = LidCloseActionJournal.Record(
            sessionID: UUID(),
            startedAt: "2026-11-08T10:00:00Z",
            audio: [.init(deviceUID: "BuiltInSpeakerDevice", wasMuted: false, volume: 0.4)],
            stopped: [.init(pid: 4711, startSeconds: 1_700_000_000, startMicroseconds: 123,
                            bootID: "A", path: "/Applications/Slack.app/Contents/MacOS/Slack",
                            appName: "Slack")])
        XCTAssertTrue(journal.save(record))
        XCTAssertEqual(journal.load(), record)
    }

    func testMissingFileReadsEmpty() {
        let (journal, _) = makeJournal()
        XCTAssertTrue(journal.load().isEmpty)
        XCTAssertEqual(journal.load().stopped, [])
    }

    /// A corrupt file reads as EMPTY, and that is the documented cost: a
    /// destroyed journal means a stopped process stays stopped until the
    /// operator notices. Refusing every read would instead leave a muted Mac
    /// muted forever, which is worse.
    func testCorruptFileReadsEmpty() throws {
        let (journal, url) = makeJournal()
        try Data("not json at all".utf8).write(to: url)
        XCTAssertTrue(journal.load().isEmpty)
    }

    /// A key added by a later version must not make an existing journal read as
    /// empty — that would silently lose the undo.
    func testFutureKeyIsTolerated() throws {
        let (journal, url) = makeJournal()
        let json = """
        {"schemaVersion":1,"audio":{"deviceUID":"X","wasMuted":false},
         "stopped":[],"futureKey":"whatever"}
        """
        try Data(json.utf8).write(to: url)
        let rec = journal.load()
        XCTAssertEqual(rec.audio.first?.deviceUID, "X")
    }

    /// The record is written atomically: a partially-written file never reads
    /// as a valid record with half the entries.
    func testWriteIsAtomic() {
        let (journal, url) = makeJournal()
        var rec = LidCloseActionJournal.Record()
        for pid in Int32(1)...20 {
            rec.stopped.append(.init(pid: pid, startSeconds: 1, startMicroseconds: 0,
                                     bootID: "A", path: "/x", appName: "Slack"))
            XCTAssertTrue(journal.save(rec))
            XCTAssertEqual(journal.load().stopped.count, Int(pid))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearRemovesTheFile() {
        let (journal, url) = makeJournal()
        journal.save(.init(audio: [.init(deviceUID: "X", wasMuted: false, volume: nil)]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        journal.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(journal.load().isEmpty)
    }

    /// `unverified` is NOT part of `isEmpty`: an unproven process is still an
    /// outstanding obligation, so the journal must stay.
    func testUnverifiedKeepsTheRecordNonEmptyByDesign() {
        var rec = LidCloseActionJournal.Record()
        rec.unverified = [.init(pid: 4711, startSeconds: 1, startMicroseconds: 0,
                                bootID: "A", path: "/x", appName: "Slack")]
        XCTAssertTrue(rec.isEmpty, "isEmpty describes the EFFECTS, not the obligations")
        XCTAssertFalse(rec.unverified.isEmpty)
    }

    /// The canonical path lives in Application Support with the other stores,
    /// never in `~/Library/Logs/RunClosed/` (launchd's stderr).
    func testCanonicalPathIsInApplicationSupport() {
        let url = LidCloseActionJournal().url
        XCTAssertTrue(url.path.contains("Application Support/RunClosed"))
        XCTAssertTrue(url.lastPathComponent == "lid_close_actions.json")
        XCTAssertFalse(url.path.contains("Logs/RunClosed"))
    }

    /// The audio entry names the device by UID, and the prior state travels with
    /// it so the undo can restore it exactly.
    func testAudioStateCarriesPriorState() {
        let state = LidCloseActionJournal.AudioState(
            deviceUID: "BuiltInSpeakerDevice", wasMuted: false, volume: 0.5)
        XCTAssertEqual(state.volume, 0.5)
        XCTAssertFalse(state.wasMuted)

        let alreadyMuted = LidCloseActionJournal.AudioState(
            deviceUID: "X", wasMuted: true, volume: nil)
        XCTAssertTrue(alreadyMuted.wasMuted)
        XCTAssertNil(alreadyMuted.volume)
    }

    /// The identity triple is what `identityProved` compares, so it must
    /// round-trip through the file unchanged.
    func testIdentityTripleRoundTrips() {
        let (journal, _) = makeJournal()
        let entry = LidCloseActionJournal.StoppedProcess(
            pid: 4711, startSeconds: 1_700_000_000, startMicroseconds: 654321,
            bootID: "BOOT-A", path: "/Applications/Discord.app/Contents/MacOS/Discord",
            appName: "Discord")
        journal.save(.init(stopped: [entry]))
        let back = journal.load().stopped.first
        XCTAssertEqual(back?.identity, entry.identity)
        XCTAssertEqual(back?.identity.startMicroseconds, 654321)
        XCTAssertEqual(back?.identity.bootID, "BOOT-A")
    }

    /// A reopened record carries the previous `unverified` list forward: a new
    /// episode must not erase an obligation the operator has not been told about.
    func testReopeningCarriesUnverifiedForward() {
        var rec = LidCloseActionJournal.Record()
        rec.unverified = [.init(pid: 4711, startSeconds: 1, startMicroseconds: 0,
                                bootID: "A", path: "/x", appName: "Slack")]
        let next = LidCloseActionJournal.Record().reopened(sessionID: UUID(),
                                                           at: "2026-11-08T10:00:00Z")
        XCTAssertTrue(next.unverified.isEmpty)
        // The carry is done by `apply`, from the record it read; this asserts
        // the SHAPE it starts from, so a refactor cannot silently drop it.
        XCTAssertEqual(rec.unverified.count, 1)
    }
}

/// Corrupt-entry survival (Lord round 5, point 3).
final class LidCloseActionCorruptEntryTests: XCTestCase {

    /// (c) One MALFORMED audio entry must not erase the healthy ones: the file
    /// still parses, so a whole-array `try?` would silently drop every
    /// restoration obligation while reporting a valid journal (Lord round 5,
    /// point 3). The healthy entries survive AND the loss is reported.
    func testOneCorruptAudioEntryLeavesTheHealthyOnes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-badentry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lid_close_actions.json")

        // A good entry, then one whose `volume` is a String — decodable as JSON,
        // not as AudioState.
        let json = """
        {"schemaVersion":1,
         "audio":[{"deviceUID":"Headphones","wasMuted":false,"volume":0.7},
                  {"deviceUID":"Broken","wasMuted":false,"volume":"loud"}],
         "stopped":[],"unverified":[],"unverifiedAudio":[]}
        """
        try Data(json.utf8).write(to: url)

        let journal = LidCloseActionJournal(url: url)
        let rec = journal.load()

        XCTAssertEqual(rec.audio.map { $0.deviceUID }, ["Headphones"],
                       "a malformed entry erased the healthy obligation")
        XCTAssertTrue(rec.hasDroppedAudioEntries,
                      "the lost entry was not reported")
        XCTAssertTrue(journal.isCorrupt,
                      "a journal that lost an entry reported as healthy")
    }

    /// A mis-typed DAMAGE COUNTER must not cost the obligations next to it.
    ///
    /// The counters are diagnostic metadata. Decoding them with a hard `try`
    /// threw out of the whole `Record`, so `load()` returned an EMPTY record and
    /// every valid audio and process entry in that same file became unreachable:
    /// a device left muted, apps left frozen, with only `isCorrupt` to say so
    /// (gate finding, `Malformed damage counters discard all valid recovery
    /// entries`).
    ///
    /// Counter-proof: with `try` this reads an empty `audio` list.
    func testAMisTypedDamageCounterKeepsTheObligations() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-badcounter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lid_close_actions.json")

        let json = """
        {"schemaVersion":1,
         "audio":[{"deviceUID":"Headphones","wasMuted":false,"volume":0.7}],
         "stopped":[{"pid":4711,"startSeconds":1700000000,"startMicroseconds":0,
                     "bootID":"A","path":"/Applications/Slack.app/Contents/MacOS/Slack",
                     "appName":"Slack"}],
         "unverified":[],"unverifiedAudio":[],
         "droppedAudioEntries":"1"}
        """
        try Data(json.utf8).write(to: url)

        let rec = LidCloseActionJournal(url: url).load()

        XCTAssertEqual(rec.audio.map { $0.deviceUID }, ["Headphones"],
                       "a bad COUNTER discarded a valid audio obligation")
        XCTAssertEqual(rec.stopped.map { $0.pid }, [4711],
                       "a bad COUNTER discarded a valid process obligation")
    }

}

/// Legacy-shape decoding.
final class LidCloseActionLegacyDecodeTests: XCTestCase {

    /// A journal written by the EARLIER build (singular `unverifiedAudio`) is
    /// supported, not corrupt: reporting it as damaged made `lid-close status`
    /// exit 3 over a perfectly good file while no entry was lost (gate finding,
    /// `Supported legacy audio records trigger false corruption reports`).
    func testLegacySingularAudioIsNotReportedAsCorrupt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lid_close_actions.json")

        // The shape the previous build wrote: one OBJECT, not an array.
        let legacy = """
        {"schemaVersion":1,
         "audio":{"deviceUID":"BuiltInSpeakerDevice","wasMuted":false,"volume":0.5},
         "stopped":[],"unverified":[],
         "unverifiedAudio":{"deviceUID":"Headphones","wasMuted":false,"volume":0.7}}
        """
        try Data(legacy.utf8).write(to: url)

        let journal = LidCloseActionJournal(url: url)
        let rec = journal.load()

        XCTAssertEqual(rec.audio.first?.deviceUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(rec.unverifiedAudio.first?.deviceUID, "Headphones")
        XCTAssertFalse(rec.hasDroppedAudioEntries,
                       "a supported legacy record was counted as damage")
        XCTAssertFalse(journal.isCorrupt,
                       "a supported legacy record was reported as corrupt")
    }

}

/// The kill switch an operator reaches for in a hurry (ADR 026).
///
/// `defaults write com.benjaminbelaga.RunClosed lidCloseActions -bool false`
/// replaces the stored JSON blob with a Boolean. The store must read that as
/// "off" — not as corrupt-and-ignore, and not by crashing — so the operator can
/// always disable the feature without a rebuild, and the policy's answer for a
/// non-empty journal becomes `.undo`, which restores the sound on the next tick.
final class LidCloseActionSettingsKillSwitchTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "com.benjaminbelaga.RunClosed.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        UserDefaults.standard.set(suite, forKey: "runclosed.test.suite.\(ObjectIdentifier(self))")
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (defaults, suite)
    }

    func testAbsentKeyIsOffByDefault() {
        let (defaults, _) = makeDefaults()
        let settings = LidCloseActionSettingsStore.load(from: defaults)
        XCTAssertFalse(settings.enabled, "the feature must be OFF when nothing was written")
    }

    func testRoundTripThroughTheStore() {
        let (defaults, _) = makeDefaults()
        let written = LidCloseActionSettings(enabled: true, muteAudio: false, pauseApps: true,
                                             pausedApps: ["Slack"])
        XCTAssertTrue(LidCloseActionSettingsStore.save(written, to: defaults))
        XCTAssertEqual(LidCloseActionSettingsStore.load(from: defaults), written)
    }

    /// The kill switch: a Boolean where the store expects its blob reads as OFF.
    func testBooleanKillSwitchReadsAsOff() {
        let (defaults, _) = makeDefaults()
        LidCloseActionSettingsStore.save(.init(enabled: true, pauseApps: true), to: defaults)
        XCTAssertTrue(LidCloseActionSettingsStore.load(from: defaults).enabled)

        // `defaults write com.benjaminbelaga.RunClosed lidCloseActions -bool false`
        defaults.set(false, forKey: LidCloseActionSettingsStore.key)

        let after = LidCloseActionSettingsStore.load(from: defaults)
        XCTAssertFalse(after.enabled, "the kill switch did not disable the feature")
        XCTAssertFalse(after.pauseApps)
    }

    /// And it is a real kill switch in the policy sense: with the journal
    /// non-empty and the switch off, the answer is `.undo`, so the next tick
    /// restores the sound instead of leaving the Mac muted.
    func testBooleanKillSwitchMakesTheNextDecisionUndo() {
        let (defaults, _) = makeDefaults()
        LidCloseActionSettingsStore.save(.init(enabled: true), to: defaults)
        defaults.set(false, forKey: LidCloseActionSettingsStore.key)

        let settings = LidCloseActionSettingsStore.load(from: defaults)
        let decision = LidCloseActionPolicy.decide(
            .init(sessionActive: true, lidClosed: true, externalDisplayConnected: false,
                  settings: settings),
            currentlyApplied: true)
        XCTAssertEqual(decision.action, .undo)
        XCTAssertEqual(decision.reason, .switchedOff)
    }

    /// A store with no domain (an unbundled dev run) is not a crash: it reads
    /// the compiled-in defaults.
    func testNilDomainReadsDefaults() {
        XCTAssertFalse(LidCloseActionSettingsStore.load(from: nil).enabled)
    }
}
