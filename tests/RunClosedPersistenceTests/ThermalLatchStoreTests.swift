import XCTest
@testable import RunClosedCore
@testable import RunClosedPersistence

/// `ThermalLatchStore` (ADR 025): the same discipline as
/// `LowBatteryLatchStore` — `schemaVersion`, `.atomic` writes, and a
/// missing/corrupt file reading as the default latch. That last property is
/// what stops a damaged file from looking like "already released for heat"
/// (which would silence the next episode) or "already warned" (which would
/// swallow its first alert).
final class ThermalLatchStoreTests: XCTestCase {

    private func tempURL(_ name: String = "thermal_guard.json") -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-latch-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name)
    }

    func testMissingFileReadsAsTheDefaultLatch() {
        let store = ThermalLatchStore(url: tempURL())
        let rec = store.load()
        XCTAssertEqual(rec.latch, ThermalPolicy.Latch())
        XCTAssertEqual(rec.schemaVersion, kThermalLatchSchemaVersion)
    }

    func testRoundTrip() {
        let store = ThermalLatchStore(url: tempURL())
        let latch = ThermalPolicy.Latch(warnedSerious: true, warnedCritical: true,
                                        seriousSince: 42.5, seriousSinceBootID: "A",
                                        releasedForHeat: true)
        store.save(.init(latch: latch))
        XCTAssertEqual(store.load().latch, latch)
    }

    func testCorruptFileReadsAsTheDefaultLatch() {
        let url = tempURL()
        try? Data("{not json at all".utf8).write(to: url)
        XCTAssertEqual(ThermalLatchStore(url: url).load().latch, ThermalPolicy.Latch())
    }

    func testEmptyFileReadsAsTheDefaultLatch() {
        let url = tempURL()
        try? Data().write(to: url)
        XCTAssertEqual(ThermalLatchStore(url: url).load().latch, ThermalPolicy.Latch())
    }

    /// A key written by a LATER version must not make the whole record
    /// unreadable: dropping `releasedForHeat` would silently erase the "heat
    /// ended the session" signal and re-arm the alert.
    func testAFutureSchemaVersionIsStillReadable() throws {
        let url = tempURL()
        let json = """
        {"schemaVersion":99,
         "latch":{"warnedSerious":true,"warnedCritical":false,"seriousSince":7,
                  "seriousSinceBootID":"A","releasedForHeat":true,"futureKey":"x"},
         "updatedAt":"2026-11-07T10:00:00Z"}
        """
        try Data(json.utf8).write(to: url)
        let rec = ThermalLatchStore(url: url).load()
        XCTAssertTrue(rec.latch.releasedForHeat)
        XCTAssertTrue(rec.latch.warnedSerious)
        XCTAssertEqual(rec.latch.seriousSince, 7)
    }

    func testSaveStampsUpdatedAt() {
        let store = ThermalLatchStore(url: tempURL())
        store.save(.init(latch: ThermalPolicy.Latch()))
        XCTAssertNotNil(store.load().updatedAt)
    }

    func testSaveIsAtomicAndOverwrites() {
        let store = ThermalLatchStore(url: tempURL())
        store.save(.init(latch: ThermalPolicy.Latch(releasedForHeat: true)))
        store.save(.init(latch: ThermalPolicy.Latch(releasedForHeat: false)))
        XCTAssertFalse(store.load().latch.releasedForHeat, "the second save replaced the first")
    }

    /// The canonical path is the shared state directory, NOT
    /// `~/Library/Logs/RunClosed/` (which holds launchd's captured stderr).
    func testCanonicalPathLivesUnderApplicationSupport() {
        let url = ThermalLatchStore().url
        XCTAssertTrue(url.path.contains("/Application Support/RunClosed/"), url.path)
        XCTAssertEqual(url.lastPathComponent, "thermal_guard.json")
        XCTAssertFalse(url.path.contains("/Logs/"), "stores are not logs")
    }
}
