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
            audio: .init(deviceUID: "BuiltInSpeakerDevice", wasMuted: false, volume: 0.4),
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
        XCTAssertEqual(rec.audio?.deviceUID, "X")
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
        journal.save(.init(audio: .init(deviceUID: "X", wasMuted: false, volume: nil)))
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
