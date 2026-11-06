import XCTest
@testable import RunClosedCore
@testable import RunClosedPersistence

/// `session.json` contract (ADR 023 §2): round-trip, schema version, damaged
/// file loads as EMPTY (never as a phantom deadline), and the CLI-readable
/// shape stays a plain JSON object.
final class SessionStoreTests: XCTestCase {

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    private func sample() -> KeepAwakeSession {
        KeepAwakeSession(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endsAtWall: Date(timeIntervalSince1970: 1_800_003_600),
            endsAtContinuous: 12_345_678_900,
            bootID: "boot-A")
    }

    func testMissingFileHasNoSession() {
        let store = SessionStore(url: tempURL())
        XCTAssertNil(store.load())
        XCTAssertFalse(store.exists)
        XCTAssertNil(store.storedSchemaVersion())
    }

    func testRoundTrip() {
        let store = SessionStore(url: tempURL())
        let session = sample()
        store.save(session)
        XCTAssertTrue(store.exists)
        let loaded = store.load()
        XCTAssertEqual(loaded, session)
        XCTAssertEqual(loaded?.schemaVersion, kKeepAwakeSessionSchemaVersion)
    }

    func testRoundTripPreservesPauseAndOptionalDeadlines() {
        let store = SessionStore(url: tempURL())
        let paused = SessionPolicy.pause(sample(), reason: .lowBattery)
        store.save(paused)
        XCTAssertEqual(store.load()?.pausedReason, .lowBattery)

        let indefinite = KeepAwakeSession(startedAt: Date(), bootID: "boot-A")
        store.save(indefinite)
        let loaded = store.load()
        XCTAssertEqual(loaded?.isIndefinite, true)
        XCTAssertNil(loaded?.endsAtWall)
        XCTAssertNil(loaded?.endsAtContinuous)
    }

    func testClearRemovesTheRecord() {
        let store = SessionStore(url: tempURL())
        store.save(sample())
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertFalse(store.exists)
        // Clearing twice is not an error (End pressed after expiry).
        store.clear()
        XCTAssertNil(store.load())
    }

    func testDamagedFileLoadsAsEmpty() {
        for garbage in ["{not json", "", "[]", #"{"schemaVersion":1}"#] {
            let url = tempURL()
            try? Data(garbage.utf8).write(to: url)
            XCTAssertNil(SessionStore(url: url).load(), "garbage: \(garbage.debugDescription)")
        }
    }

    func testDamagedFileIsNotSilentlyRewritten() {
        // `load()` must be a pure read: a corrupt file stays put until a real
        // write decides what to do with it.
        let url = tempURL()
        try? Data("{oops".utf8).write(to: url)
        _ = SessionStore(url: url).load()
        XCTAssertEqual(try? Data(contentsOf: url), Data("{oops".utf8))
    }

    func testSchemaVersionIsReported() {
        let store = SessionStore(url: tempURL())
        store.save(sample())
        XCTAssertEqual(store.storedSchemaVersion(), kKeepAwakeSessionSchemaVersion)
    }

    func testFutureSchemaVersionStillDecodes() {
        // Forward compatibility: L2's backstop / L4's lid actions will add
        // keys. An unknown key must not make a live deadline vanish.
        let url = tempURL()
        let json = """
        {"schemaVersion": 99,
         "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
         "startedAt": "2027-01-01T10:00:00Z",
         "endsAtWall": "2027-01-01T12:00:00Z",
         "endsAtContinuous": 999,
         "bootID": "boot-A",
         "pausedReason": null,
         "futureKey": {"thermal": "warm"}}
        """
        try? Data(json.utf8).write(to: url)
        let loaded = SessionStore(url: url).load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.bootID, "boot-A")
        XCTAssertEqual(loaded?.schemaVersion, 99)
        XCTAssertEqual(SessionStore(url: url).storedSchemaVersion(), 99)
    }

    func testBareSessionObjectIsAccepted() {
        // A record written by another tool (the L2 backstop) in the plain
        // shape must be readable, not treated as corruption.
        let url = tempURL()
        let json = """
        {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
         "startedAt": "2027-01-01T10:00:00Z",
         "bootID": "boot-A"}
        """
        try? Data(json.utf8).write(to: url)
        let loaded = SessionStore(url: url).load()
        XCTAssertEqual(loaded?.bootID, "boot-A")
        XCTAssertEqual(loaded?.isIndefinite, true)
    }

    func testWriteIsReadableAsPlainJSON() throws {
        // The CLI prints this file; keeping it a flat JSON object with
        // ISO-8601 dates is part of the contract.
        let url = tempURL()
        SessionStore(url: url).save(sample())
        let obj = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let session = obj?["session"] as? [String: Any]
        XCTAssertNotNil(session)
        XCTAssertEqual(session?["bootID"] as? String, "boot-A")
        XCTAssertEqual(session?["endsAtWall"] as? String, "2027-01-15T09:00:00Z")
    }

    func testCanonicalPathIsUnderApplicationSupport() {
        let store = SessionStore()
        XCTAssertTrue(store.url.path.hasSuffix("/Library/Application Support/RunClosed/session.json"),
                      store.url.path)
    }
}
