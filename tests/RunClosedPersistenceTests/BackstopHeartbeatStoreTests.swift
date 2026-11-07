import XCTest
import Foundation
@testable import RunClosedPersistence

/// The backstop heartbeat store (ADR 024 §5): the proof that the agent RUNS,
/// as opposed to merely being registered. Same discipline as the other stores.
final class BackstopHeartbeatStoreTests: XCTestCase {

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-heartbeat-\(UUID().uuidString)", isDirectory: true)
        // Every test leaves its own directory behind otherwise: the suite runs
        // repeatedly in CI and on dev machines, and the orphaned trees in
        // NSTemporaryDirectory grow without any cleanup (review round 7). The
        // sibling RecoveryBackstopServiceTests already tears its rigs down.
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("backstop_heartbeat.json")
    }

    private let when = Date(timeIntervalSince1970: 1_800_000_000)

    func testRoundTrip() {
        let store = BackstopHeartbeatStore(url: tempURL())
        try? FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let record = BackstopHeartbeatStore.Record(at: when, bootID: "A", exitCode: 0,
                                                   rearmWithheldReported: true)
        XCTAssertTrue(store.save(record))
        XCTAssertEqual(store.load(), record)
    }

    /// A missing file is "no proof", never a phantom recent run.
    func testMissingFileIsNil() {
        XCTAssertNil(BackstopHeartbeatStore(url: tempURL()).load())
    }

    /// Corrupt content is absent, not a crash and not a guess (B3).
    func testCorruptFileIsNil() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)
        XCTAssertNil(BackstopHeartbeatStore(url: url).load())
    }

    /// A key a later version adds must not lose the proof the file carries.
    func testFutureKeyIsTolerated() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let json = """
        {"schemaVersion": 2, "at": "2027-01-15T10:00:00Z", "bootID": "A",
         "exitCode": 5, "somethingNew": true}
        """
        try Data(json.utf8).write(to: url)
        let rec = try XCTUnwrap(BackstopHeartbeatStore(url: url).load())
        XCTAssertEqual(rec.bootID, "A")
        XCTAssertEqual(rec.exitCode, 5)
        XCTAssertFalse(rec.rearmWithheldReported, "an absent flag defaults to 'not reported'")
    }

    /// Dates are ISO-8601 on disk, so `jq` and the CLI can read them.
    func testDatesAreISO8601OnDisk() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(BackstopHeartbeatStore(url: url).save(
            .init(at: when, bootID: "A", exitCode: 0)))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("2027-01-15T"), text)
        XCTAssertTrue(text.contains("\"bootID\""), text)
    }

    /// The canonical path is where the README and the CLI say it is.
    func testCanonicalPath() {
        let url = BackstopHeartbeatStore().url
        XCTAssertEqual(url.lastPathComponent, "backstop_heartbeat.json")
        XCTAssertTrue(url.path.contains("Application Support/RunClosed"), url.path)
    }

    /// Writing twice replaces the record atomically — a stale proof must never
    /// survive a newer run.
    func testSaveReplacesTheRecord() {
        let store = BackstopHeartbeatStore(url: tempURL())
        try? FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        store.save(.init(at: when, bootID: "A", exitCode: 0))
        store.save(.init(at: when.addingTimeInterval(60), bootID: "A", exitCode: 5))
        XCTAssertEqual(store.load()?.exitCode, 5)
        XCTAssertEqual(store.load()?.at, when.addingTimeInterval(60))
    }
}
