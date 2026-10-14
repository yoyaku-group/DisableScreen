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

    func testOlderFileWithoutNewKeysKeepsPendingRearm() {
        // Forward compatibility: a key added later must not make an existing
        // file decode as corrupt (which would silently drop releasedByGuard).
        let url = tempURL()
        try? Data(#"{"schemaVersion":1,"latch":{"warnedLow":true,"warnedCritical":false,"releasedByGuard":true}}"#.utf8).write(to: url)
        let rec = LowBatteryLatchStore(url: url).load()
        XCTAssertTrue(rec.latch.releasedByGuard)
        XCTAssertTrue(rec.latch.warnedLow)
        XCTAssertFalse(rec.latch.failedReleaseSleepTried)
    }

    func testLidWriteLockSerializesSections() {
        let lock = LidWriteLock(url: tempURL().deletingLastPathComponent().appendingPathComponent("lid.lock"))
        final class Counter: @unchecked Sendable {
            let m = NSLock()
            var inside = 0
            var maxInside = 0
        }
        let c = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            lock.withLock {
                c.m.lock(); c.inside += 1; c.maxInside = max(c.maxInside, c.inside); c.m.unlock()
                Thread.sleep(forTimeInterval: 0.01)
                c.m.lock(); c.inside -= 1; c.m.unlock()
            }
        }
        XCTAssertEqual(c.maxInside, 1, "flock must serialise writers (one fd per section)")
    }

    func testCorruptFileNeverYieldsPhantomRelease() {
        let url = tempURL()
        try? Data("{not json".utf8).write(to: url)
        let rec = LowBatteryLatchStore(url: url).load()
        XCTAssertFalse(rec.latch.releasedByGuard, "corrupt → default, never an automatic re-arm")
    }
}
