import XCTest
@testable import RunClosedPersistence
import RunClosedCore

/// Persistence-layer contract: save/load round-trip + missing-file behavior +
/// reap-on-load honoring the clock's bootID.
///
/// These tests use an injected URL pointing at a temp file so they do not touch
/// the user's real `~/Library/Application Support/RunClosed/leases.json`.
final class LeaseStoreTests: XCTestCase {

    /// Minimal controllable clock — the Core doesn't ship a FakeClock yet, and
    /// SystemClock's `nowMonotonic` reads real uptime (untestable in isolation).
    private struct FakeClock: Clock {
        let bootID: String
        let nowMonotonic: Double
        init(bootID: String, nowMonotonic: Double = 1000) {
            self.bootID = bootID
            self.nowMonotonic = nowMonotonic
        }
    }

    private func makeTempURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("runclosed-persistence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("leases.json")
    }

    func testRoundTripPreservesLeases() throws {
        let url = try makeTempURL()
        let clock = FakeClock(bootID: "boot-A")
        let store = LeaseStore(clock: clock, url: url)

        var engine = LeaseEngine()
        _ = engine.acquire(
            owner: "test-owner",
            sessionID: "session-1",
            pid: 4242,
            workSource: .observation,
            idleSleep: true,
            closedLid: false,
            ttl: 600,
            clock: clock
        )

        store.save(engine)
        let loaded = store.load()

        XCTAssertEqual(loaded.leases.count, 1)
        XCTAssertEqual(loaded.leases.first?.owner, "test-owner")
        XCTAssertEqual(loaded.leases.first?.sessionID, "session-1")
        XCTAssertEqual(loaded.leases.first?.bootID, "boot-A")
        XCTAssertEqual(loaded.leases.first?.requestedIdleSleep, true)
        XCTAssertEqual(loaded.leases.first?.deadlineMonotonic, 1600)   // 1000 + 600
    }

    func testMissingFileReturnsEmptyEngine() throws {
        let url = try makeTempURL()   // never written
        let clock = FakeClock(bootID: "boot-A")
        let store = LeaseStore(clock: clock, url: url)

        let loaded = store.load()
        XCTAssertEqual(loaded.leases.count, 0)
    }

    func testReapOnLoadDropsOtherBootLeases() throws {
        let url = try makeTempURL()
        // Hand-craft a JSON file containing a lease tagged boot-B with a
        // future deadline — without reap, it would survive the load.
        let bootBLease = Lease(
            id: "lease-stale",
            owner: "other-boot-owner",
            sessionID: "session-B",
            pid: nil,
            bootID: "boot-B",
            workSource: .observation,
            state: .working,
            requestedIdleSleep: true,
            requestedClosedLid: false,
            deadlineMonotonic: 999999
        )
        let data = try JSONEncoder().encode([bootBLease])
        try data.write(to: url)

        // Load with a clock claiming boot-A → the boot-B lease must be reaped.
        let clockA = FakeClock(bootID: "boot-A", nowMonotonic: 100)
        let storeA = LeaseStore(clock: clockA, url: url)
        let loaded = storeA.load()
        XCTAssertEqual(loaded.leases.count, 0,
                       "lease from a different boot must be reaped on load")
    }

    func testReapOnLoadDropsExpiredLeases() throws {
        let url = try makeTempURL()
        let clock = FakeClock(bootID: "boot-A", nowMonotonic: 5000)
        let store = LeaseStore(clock: clock, url: url)

        // Write a lease whose deadline has already passed.
        let expired = Lease(
            id: "lease-expired",
            owner: "old-owner",
            sessionID: "session-expired",
            pid: nil,
            bootID: "boot-A",
            workSource: .observation,
            state: .working,
            requestedIdleSleep: true,
            requestedClosedLid: false,
            deadlineMonotonic: 100
        )
        let data = try JSONEncoder().encode([expired])
        try data.write(to: url)

        let loaded = store.load()
        XCTAssertEqual(loaded.leases.count, 0,
                       "expired lease must be reaped on load")
    }

    func testAtomicWriteLeavesNoTempFile() throws {
        let url = try makeTempURL()
        let clock = FakeClock(bootID: "boot-A")
        let store = LeaseStore(clock: clock, url: url)

        var engine = LeaseEngine()
        _ = engine.acquire(
            owner: "owner", sessionID: "s1", pid: nil,
            workSource: .observation, idleSleep: true, closedLid: false,
            ttl: 60, clock: clock
        )
        store.save(engine)

        // After a successful atomic write, only the canonical file should exist —
        // no leftover temp sibling.
        let dir = url.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(contents, ["leases.json"],
                       "atomic write must not leave temp sibling files")
    }
}
