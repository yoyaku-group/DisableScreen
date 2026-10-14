import XCTest
@testable import RunClosedCore
@testable import RunClosedPersistence

final class LowBatteryLatchStoreTests: XCTestCase {

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-latch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("low_battery_guard.json")
    }

    func testMissingFileGivesDefaultLatch() {
        let store = LowBatteryLatchStore(url: tempURL())
        XCTAssertEqual(store.load().latch, LowBatteryPolicy.Latch())
    }

    func testRoundTrip() {
        let store = LowBatteryLatchStore(url: tempURL())
        let latch = LowBatteryPolicy.Latch(warnedLow: true, warnedCritical: false, releasedByGuard: true)
        store.save(.init(latch: latch, releasedBootID: "boot-A"))
        let rec = store.load()
        XCTAssertEqual(rec.latch, latch)
        XCTAssertEqual(rec.releasedBootID, "boot-A")
        XCTAssertNotNil(rec.updatedAt)
        XCTAssertEqual(rec.schemaVersion, kLowBatteryLatchSchemaVersion)
    }

    func testCorruptFileNeverYieldsPhantomRelease() {
        let url = tempURL()
        try? Data("{not json".utf8).write(to: url)
        let rec = LowBatteryLatchStore(url: url).load()
        XCTAssertFalse(rec.latch.releasedByGuard, "corrupt → default, never an automatic re-arm")
    }
}
