import XCTest
@testable import RunClosedMacSystem

/// Lifecycle tests for `ClamshellObserver` (ADR 025).
///
/// These deliberately do NOT assert anything about a real lid: registering an
/// IOPMrootDomain interest notification is harmless and read-only, but what
/// matters here is the LIFETIME discipline — the observer is retained for as
/// long as IOKit holds its callback, `stop()` is idempotent, and it cannot
/// deadlock by taking its own queue synchronously.
final class ClamshellObserverTests: XCTestCase {

    /// Small thread-safe counter: the handler is `@Sendable`, so the tests
    /// cannot mutate a captured `var`.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// `stop()` on an observer that never started is a no-op, not a crash.
    func testStopBeforeStartIsSafe() {
        let observer = ClamshellObserver()
        observer.stop()
        observer.stop()
    }

    /// Start then stop leaves nothing installed, and a second start after a
    /// stop does not double-register (the guard is `notifier != NULL`).
    func testStartIsIdempotentAndStopReleases() {
        let observer = ClamshellObserver()
        let fired = Counter()
        observer.start { fired.increment() }
        observer.start { fired.increment() }   // idempotent: second call is ignored
        observer.stop()
        observer.stop()                        // idempotent too
        XCTAssertEqual(fired.value, 0, "no lid moved, so nothing fired")
    }

    /// The observer is RETAINED while installed. Without the retain, a released
    /// observer would leave IOKit holding a dangling context and the next lid
    /// close would run `fromOpaque` on freed memory.
    ///
    /// Proven by weak-reference survival: the only strong reference goes away,
    /// and the object must still be alive because the IOKit hold keeps it so.
    func testTheObserverOutlivesItsLastExternalReferenceWhileInstalled() {
        weak var weakRef: ClamshellObserver?
        do {
            let observer = ClamshellObserver()
            weakRef = observer
            observer.start { }
            XCTAssertNotNil(weakRef)
        }
        // The local `observer` is gone; the IOKit retain keeps it alive.
        XCTAssertNotNil(weakRef, "an installed observer must be retained for IOKit")
        // Releasing that hold is what actually frees it.
        weakRef?.stop()
        XCTAssertNil(weakRef, "stop() gives the retain back")
    }

    /// `stop()` called from the observer's OWN queue must not deadlock. The
    /// previous implementation used `queue.sync` unconditionally, so this exact
    /// call hung forever — a menu-bar app freeze at quit.
    func testStopFromTheObserversOwnQueueDoesNotDeadlock() {
        let observer = ClamshellObserver()
        observer.start { }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let flag = Flag()
        // `scheduleTick` posts onto the observer queue; the block it runs calls
        // stop() from that very queue.
        let done = expectation(description: "stop returns from the observer queue")
        DispatchQueue.global().async {
            observer.scheduleTickForTesting {
                observer.stop()
                flag.set()
                done.fulfill()
            }
        }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 10), .completed,
                       "stop() deadlocked on its own queue")
        XCTAssertTrue(flag.isSet)
    }
}

extension ClamshellObserver {
    /// Test seam: run `body` shortly on the observer queue, through the same
    /// queue a real debounced notification uses. Lets the test exercise
    /// "teardown from inside the observer queue" without moving the lid.
    func scheduleTickForTesting(_ body: @escaping @Sendable () -> Void) {
        let work = DispatchWorkItem { body() }
        queueForTesting.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
}
