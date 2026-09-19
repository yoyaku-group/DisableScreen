import XCTest
@testable import RunClosedPersistence

/// Persistence-layer contract for the owned-disabled displays record.
///
/// Mirrors LeaseStoreTests: temp URL injection, atomic write discipline,
/// cross-boot discard.
final class OwnedDisabledDisplaysStoreTests: XCTestCase {

    private func makeTempURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("runclosed-owned-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("owned_displays.json")
    }

    func testRoundTripPreservesIDs() throws {
        let url = try makeTempURL()
        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)

        let record = OwnedDisabledDisplays.Record(bootID: "boot-A", ids: [10, 20, 30])
        store.save(record)
        let loaded = store.load()

        XCTAssertEqual(loaded.bootID, "boot-A")
        XCTAssertEqual(loaded.ids.sorted(), [10, 20, 30])
    }

    func testMissingFileReturnsEmptyRecord() throws {
        let url = try makeTempURL()   // never written
        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)
        let loaded = store.load()

        XCTAssertEqual(loaded.bootID, "boot-A")
        XCTAssertTrue(loaded.ids.isEmpty)
    }

    func testCorruptFileReturnsEmptyRecord() throws {
        let url = try makeTempURL()
        try "{not json".data(using: .utf8)!.write(to: url)

        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)
        let loaded = store.load()

        // We never crash on corrupt JSON; we discard and return empty.
        // This is the B3 discipline: never assume ownership.
        XCTAssertTrue(loaded.ids.isEmpty)
    }

    func testStaleBootRecordIsDiscarded() throws {
        let url = try makeTempURL()
        let staleStore = OwnedDisabledDisplays(currentBootID: "boot-OTHER", url: url)
        staleStore.save(.init(bootID: "boot-OTHER", ids: [42, 99]))

        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)
        let loaded = store.load()

        XCTAssertEqual(loaded.bootID, "boot-A")
        XCTAssertTrue(loaded.ids.isEmpty,
                       "previous-boot ownership must be discarded — re-enabling them blindly is unsafe")
    }

    func testAtomicWriteLeavesNoTempFile() throws {
        let url = try makeTempURL()
        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)

        store.save(.init(bootID: "boot-A", ids: [1, 2, 3]))

        let dir = url.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(contents, ["owned_displays.json"],
                       "atomic write must not leave a temp sibling file")
    }

    func testRecordSchemaVersionIsCarried() throws {
        let url = try makeTempURL()
        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)
        store.save(.init(bootID: "boot-A", ids: [7]))

        // Re-decode the raw JSON to verify the schemaVersion is on disk.
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(obj?["bootID"] as? String, "boot-A")
        XCTAssertEqual((obj?["ids"] as? [UInt32]) ?? [], [7])
    }
}
