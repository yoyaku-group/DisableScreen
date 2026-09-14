import XCTest
@testable import RunClosedCore

final class FakeClock: Clock, @unchecked Sendable {
    var now: Double
    var boot: String
    init(now: Double = 1000, boot: String = "BOOT-A") { self.now = now; self.boot = boot }
    var nowMonotonic: Double { now }
    var bootID: String { boot }
}

final class LeaseEngineTests: XCTestCase {

    func testAcquireIsIdempotentPerOwnerSession() {
        let clock = FakeClock()
        var e = LeaseEngine()
        let a = e.acquire(owner: "cli", sessionID: "s1", pid: 1, workSource: .wrapper,
                          idleSleep: true, closedLid: false, ttl: 100, clock: clock)
        let b = e.acquire(owner: "cli", sessionID: "s1", pid: 1, workSource: .wrapper,
                          idleSleep: true, closedLid: false, ttl: 200, clock: clock)
        XCTAssertEqual(e.leases.count, 1, "renew must not create a second lease")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(e.leases[0].deadlineMonotonic, 1200, accuracy: 0.001)
    }

    func testExpiredLeaseIsReaped() {
        let clock = FakeClock(now: 1000)
        var e = LeaseEngine()
        _ = e.acquire(owner: "cli", sessionID: "s1", pid: nil, workSource: .wrapper,
                      idleSleep: true, closedLid: false, ttl: 50, clock: clock)
        clock.now = 1100                       // past the deadline (1050)
        XCTAssertEqual(e.reap(clock: clock), 1)
        XCTAssertTrue(e.leases.isEmpty)
        XCTAssertFalse(e.decide(clock: clock).keepAwake)
    }

    func testLeaseFromAnotherBootIsInvalid() {
        let clock = FakeClock(now: 1000, boot: "BOOT-A")
        var e = LeaseEngine()
        _ = e.acquire(owner: "cli", sessionID: "s1", pid: nil, workSource: .wrapper,
                      idleSleep: true, closedLid: false, ttl: 10_000, clock: clock)
        clock.boot = "BOOT-B"                  // reboot: monotonic deadline no longer valid
        XCTAssertEqual(e.reap(clock: clock), 1)
        XCTAssertFalse(e.decide(clock: clock).keepAwake)
    }

    func testDecideKeepsAwakeOnlyForWorkingOrWaiting() {
        let clock = FakeClock()
        var e = LeaseEngine()
        _ = e.acquire(owner: "cli", sessionID: "s1", pid: nil, workSource: .wrapper,
                      idleSleep: true, closedLid: false, ttl: 100, clock: clock)
        XCTAssertTrue(e.decide(clock: clock).keepAwake)
        e.setState(owner: "cli", sessionID: "s1", .completed)
        XCTAssertFalse(e.decide(clock: clock).keepAwake, "completed work must not keep awake (inv. 8)")
    }

    func testReleaseLastLeaseDoesNotForceSleepOfOthers() {
        let clock = FakeClock()
        var e = LeaseEngine()
        _ = e.acquire(owner: "cli", sessionID: "s1", pid: nil, workSource: .wrapper,
                      idleSleep: true, closedLid: false, ttl: 100, clock: clock)
        _ = e.acquire(owner: "ui", sessionID: "s2", pid: nil, workSource: .manual,
                      idleSleep: true, closedLid: false, ttl: 100, clock: clock)
        e.release(owner: "cli", sessionID: "s1")
        XCTAssertTrue(e.decide(clock: clock).keepAwake, "other owner's lease still holds")
        XCTAssertEqual(e.leases.count, 1)
    }
}

final class DisplayPolicyTests: XCTestCase {
    func testRefuseDeactivatingLastActiveDisplay() {
        XCTAssertFalse(DisplayPolicy.canDeactivate(target: 1, activeIDs: [1]))       // inv. 4
        XCTAssertTrue(DisplayPolicy.canDeactivate(target: 1, activeIDs: [1, 2]))
    }
    func testRefuseStaleTargetNotActive() {
        XCTAssertFalse(DisplayPolicy.canDeactivate(target: 9, activeIDs: [1, 2]))    // stale control
    }
}

final class ModelHonestyTests: XCTestCase {
    func testUnknownIsNeitherOffNorSupported() {
        // Invariant 3: unknown must be its own state.
        XCTAssertNotEqual(CapabilityStatus.unknown, .unsupported)
        XCTAssertNotEqual(CapabilityStatus.unknown, .supported)
    }
    func testFailedOperationIsNotVerified() {
        let r = OperationResult(requestID: "x", action: .brightness, state: .failed,
                                nativeRC: 9999, readbackOK: false)
        XCTAssertNotEqual(r.state, .verified)
        XCTAssertFalse(r.readbackOK)
    }
}
