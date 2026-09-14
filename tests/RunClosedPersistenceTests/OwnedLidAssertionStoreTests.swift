import XCTest
@testable import RunClosedCore
@testable import RunClosedPersistence

/// Persistence tests for `OwnedLidAssertion`. Mirrors `OwnedDisabledDisplaysStoreTests`
/// structure: round-trip, missing file, corrupt file, cross-boot discard,
/// atomic write leaves no temp, schema version carry.
final class OwnedLidAssertionStoreTests: XCTestCase {

    private func makeTempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("runclosed-lid-persist-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("owned_lid.json")
    }

    func testRoundTripPreservesOwnership() {
        let url = makeTempURL()
        let store = OwnedLidAssertion(currentBootID: "boot-A", url: url)
        store.save(.init(bootID: "boot-A", ownedEnabled: true, referenceState: "on"))

        let rec = OwnedLidAssertion(currentBootID: "boot-A", url: url).load()
        XCTAssertEqual(rec.bootID, "boot-A")
        XCTAssertTrue(rec.ownedEnabled)
        XCTAssertEqual(rec.referenceState, "on")
    }

    func testMissingFileReturnsEmptyRecord() {
        let url = makeTempURL()
        let rec = OwnedLidAssertion(currentBootID: "boot-A", url: url).load()
        XCTAssertEqual(rec.bootID, "boot-A")
        XCTAssertFalse(rec.ownedEnabled, "missing file → empty record (no phantom ownership)")
        XCTAssertEqual(rec.referenceState, "off")
    }

    func testCorruptFileReturnsEmptyRecord() {
        let url = makeTempURL()
        // Write garbage.
        try? Data("not-json{".utf8).write(to: url)
        let rec = OwnedLidAssertion(currentBootID: "boot-A", url: url).load()
        XCTAssertFalse(rec.ownedEnabled, "corrupt file → empty record (B3)")
    }

    func testStaleBootRecordIsDiscarded() {
        let url = makeTempURL()
        // Seed with a record from a DIFFERENT boot.
        let store = OwnedLidAssertion(currentBootID: "boot-OLD", url: url)
        store.save(.init(bootID: "boot-OLD", ownedEnabled: true, referenceState: "on"))

        // Reload from a new boot → must discard.
        let rec = OwnedLidAssertion(currentBootID: "boot-NEW", url: url).load()
        XCTAssertEqual(rec.bootID, "boot-NEW",
                        "cross-boot load: record.bootID must be the new bootID, not the persisted one")
        XCTAssertFalse(rec.ownedEnabled, "cross-boot load: ownership discarded (B3)")
    }

    func testAtomicWriteLeavesNoTempFile() {
        let url = makeTempURL()
        let store = OwnedLidAssertion(currentBootID: "boot-A", url: url)
        store.save(.init(bootID: "boot-A", ownedEnabled: true, referenceState: "on"))
        let parent = url.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        let temps = siblings.filter { $0.lastPathComponent.hasPrefix(".") || $0.pathExtension == "tmp" }
        let ours = temps.filter { $0.path.contains(url.lastPathComponent) }
        XCTAssertTrue(ours.isEmpty, "atomic write must not leave a sibling temp file: found \(ours)")
    }

    func testRecordSchemaVersionIsCarried() {
        let url = makeTempURL()
        let store = OwnedLidAssertion(currentBootID: "boot-A", url: url)
        store.save(.init(bootID: "boot-A", ownedEnabled: false, referenceState: "off"))
        let rec = OwnedLidAssertion(currentBootID: "boot-A", url: url).load()
        XCTAssertEqual(rec.schemaVersion, kOwnedLidSchemaVersion)
    }
}
