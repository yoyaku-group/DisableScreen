import XCTest
@testable import RunClosedPersistence

/// `app.lock` (ADR 023): held for the app's life, probed without blocking,
/// gone with the process.
final class AppLivenessLockTests: XCTestCase {

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-app-lock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.lock")
    }

    func testNotHeldWhenNobodyHoldsIt() {
        XCTAssertFalse(AppLivenessLock(url: tempURL()).isHeld())
    }

    func testHeldWhileTheAppHoldsIt() {
        let url = tempURL()
        let app = AppLivenessLock(url: url)
        XCTAssertTrue(app.hold())
        XCTAssertTrue(AppLivenessLock(url: url).isHeld())
        XCTAssertTrue(app.isHeld(), "a probe opens its own descriptor")
    }

    func testReleasedWhenTheHolderGoes() {
        let url = tempURL()
        var app: AppLivenessLock? = AppLivenessLock(url: url)
        XCTAssertEqual(app?.hold(), true)
        app = nil
        XCTAssertFalse(AppLivenessLock(url: url).isHeld())
    }

    func testASecondHolderIsRefused() {
        let url = tempURL()
        let first = AppLivenessLock(url: url)
        XCTAssertTrue(first.hold())
        XCTAssertTrue(first.hold(), "holding again is idempotent")
        XCTAssertFalse(AppLivenessLock(url: url).hold())
    }

    /// A lock file that cannot be opened reads as "nobody enforces deadlines":
    /// the CLI then refuses a timed start, the safe direction.
    func testUnopenableLockReadsAsNotHeld() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("app.lock")
        XCTAssertFalse(AppLivenessLock(url: url).isHeld())
        XCTAssertFalse(AppLivenessLock(url: url).hold())
    }

    /// A CLI probe holds the file for an instant: if the app launches right
    /// then, its first `hold()` fails. The app retries on every tick, and
    /// the retry must succeed once the probe is gone.
    func testHoldSucceedsOnRetryAfterATransientHolder() {
        let url = tempURL()
        var probe: AppLivenessLock? = AppLivenessLock(url: url)
        XCTAssertEqual(probe?.hold(), true)
        let app = AppLivenessLock(url: url)
        XCTAssertFalse(app.hold())
        probe = nil
        XCTAssertTrue(app.hold())
        XCTAssertTrue(AppLivenessLock(url: url).isHeld())
    }

    // MARK: — Review round 6

    /// Two probes at once (the CLI and the future backstop) must not see each
    /// other as the app: a probe's lock is shared, only the app's is
    /// exclusive.
    func testAProbeDoesNotReadAnotherProbeAsTheApp() {
        let url = tempURL()
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_SH | LOCK_NB), 0, "a probe in flight")
        XCTAssertFalse(AppLivenessLock(url: url).isHeld())
    }

    /// The quit teardown gives the lock up explicitly, before the process
    /// exits: a CLI queued behind it must find the app gone.
    func testReleaseGivesTheLockUpBeforeTheHolderGoes() {
        let url = tempURL()
        let app = AppLivenessLock(url: url)
        XCTAssertTrue(app.hold())
        app.release()
        XCTAssertFalse(AppLivenessLock(url: url).isHeld())
        app.release()   // idempotent
        XCTAssertTrue(app.hold(), "it can be taken again")
    }
}
