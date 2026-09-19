import XCTest
@testable import RunClosedCore
@testable import RunClosedPersistence

/// Persistence tests for `OwnedLidAssertion`. Cross-boot semantics per ADR 015
/// (BOOT CHANGE ≠ PROOF OF RESTORATION): `load()` returns records verbatim;
/// only an explicit `purge()` after an observation clears a stale record.
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

    /// ADR 015 regression — replaces the pre-015 `testStaleBootRecordIsDiscarded`:
    /// `load()` NEVER silently discards a record because the boot changed.
    /// The record comes back verbatim (with the OLD bootID) so the service
    /// layer can reconcile it against an observation. Boot change alone is
    /// never sufficient to erase state.
    func testLoadNeverDiscardsStaleBootRecord() {
        let url = makeTempURL()
        let old = OwnedLidAssertion(currentBootID: "boot-OLD", url: url)
        old.save(.init(bootID: "boot-OLD", ownedEnabled: true, referenceState: "on"))

        let rec = OwnedLidAssertion(currentBootID: "boot-NEW", url: url).load()
        XCTAssertEqual(rec.bootID, "boot-OLD",
                       "load must return the stale record verbatim — boot change is not proof of restoration")
        XCTAssertTrue(rec.ownedEnabled,
                      "load must NOT silently drop a stale ownership claim (ADR 015)")
        XCTAssertEqual(rec.referenceState, "on")
    }

    /// Boot change alone (repeated loads, no observation, no purge) never
    /// erases the record — the file on disk is untouched by `load()`.
    func testRepeatedLoadsNeverEraseStaleRecord() {
        let url = makeTempURL()
        let old = OwnedLidAssertion(currentBootID: "boot-OLD", url: url)
        old.save(.init(bootID: "boot-OLD", ownedEnabled: true, referenceState: "on"))

        for _ in 0..<3 {
            _ = OwnedLidAssertion(currentBootID: "boot-NEW", url: url).load()
        }
        let rec = OwnedLidAssertion(currentBootID: "boot-NEW", url: url).load()
        XCTAssertTrue(rec.ownedEnabled,
                      "three loads on a new boot must not erase the stale record")
    }

    /// `purge()` is the ONLY clearing path, and it is explicit.
    func testPurgeClearsTheRecordExplicitly() {
        let url = makeTempURL()
        let old = OwnedLidAssertion(currentBootID: "boot-OLD", url: url)
        old.save(.init(bootID: "boot-OLD", ownedEnabled: true, referenceState: "on"))

        let fresh = OwnedLidAssertion(currentBootID: "boot-NEW", url: url)
        fresh.purge()
        let rec = fresh.load()
        XCTAssertFalse(rec.ownedEnabled)
        XCTAssertEqual(rec.bootID, "boot-NEW")
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
