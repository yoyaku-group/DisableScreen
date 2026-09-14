import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// Service-level tests with a controllable fake mutator + a temp-file
/// OwnedLidAssertion store. Mirrors the Python main.py B1/B2 invariants.
final class LidMutationServiceTests: XCTestCase {

    /// Fake mutator — captures calls + drives success/failure AND the
    /// post-write readback value (live `PowerReadback` is not testable in
    /// unit tests; we mirror its role here).
    private final class FakeLidAssertion: LidAssertion, @unchecked Sendable {
        struct Call: Equatable {
            let enabled: Bool
        }
        private(set) var calls: [Call] = []
        var nextNativeRC: Int32 = 0
        /// What `PowerReadback.lidStayAwake()` would report AFTER our write
        /// (the readback side of the readback+write+readback loop).
        var readbackAfterWrite: Bool? = nil
        /// What the prior provider returns (set BEFORE the call).
        var observedPrior: Bool? = nil

        func setEnabled(_ enabled: Bool) -> OperationResult {
            calls.append(Call(enabled: enabled))
            if nextNativeRC != 0 {
                return OperationResult(
                    requestID: UUID().uuidString,
                    action: .sleepAll,
                    state: .failed,
                    nativeRC: Int(nextNativeRC),
                    readbackOK: false,
                    error: "fake: rc=\(nextNativeRC)"
                )
            }
            let observed = readbackAfterWrite
            let verified: Bool
            if let observed = observed {
                verified = (observed == enabled)
            } else {
                verified = false
            }
            return OperationResult(
                requestID: UUID().uuidString,
                action: .sleepAll,
                state: verified ? .verified : .failed,
                nativeRC: 0,
                readbackOK: verified,
                error: verified ? nil : "fake readback: observed=\(observed as Any), expected=\(enabled)"
            )
        }
    }

    private func makeTempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("runclosed-lid-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("owned_lid.json")
    }

    private func makeService(
        prior: Bool?,
        mutator: FakeLidAssertion,
        storeURL: URL,
        bootID: String = "boot-A"
    ) -> LidMutationService {
        let store = OwnedLidAssertion(currentBootID: bootID, url: storeURL)
        return LidMutationService(
            bootID: bootID,
            mutator: mutator,
            store: store,
            priorProvider: { prior }
        )
    }

    // MARK: — B1 invariant: unknown prior blocks the mutation

    func testSetOnRefusedOnUnknownPrior() {
        let url = makeTempURL()
        let fake = FakeLidAssertion()
        var svc = makeService(prior: nil, mutator: fake, storeURL: url)

        let r = svc.setEnabled(true)
        guard case .failure(let err) = r else {
            return XCTFail("expected failure, got \(r)")
        }
        XCTAssertEqual(err, .preconditionUnknown)
        XCTAssertTrue(fake.calls.isEmpty, "mutator must NOT be invoked when prior is unknown (B1)")
    }

    func testSetOffRefusedOnUnknownPrior() {
        let url = makeTempURL()
        let fake = FakeLidAssertion()
        var svc = makeService(prior: nil, mutator: fake, storeURL: url)

        let r = svc.setEnabled(false)
        guard case .failure(let err) = r else {
            return XCTFail("expected failure, got \(r)")
        }
        XCTAssertEqual(err, .preconditionUnknown)
        XCTAssertTrue(fake.calls.isEmpty, "mutator must NOT be invoked when prior is unknown (B1)")
    }

    // MARK: — Set ON path

    func testSetOnSucceedsWhenPriorIsOff() {
        let url = makeTempURL()
        let fake = FakeLidAssertion()
        fake.observedPrior = false
        fake.readbackAfterWrite = true
        var svc = makeService(prior: false, mutator: fake, storeURL: url)

        let r = svc.setEnabled(true)
        guard case .success(let op) = r else {
            return XCTFail("expected success, got \(r)")
        }
        XCTAssertEqual(op.state, .verified)
        XCTAssertEqual(fake.calls, [FakeLidAssertion.Call(enabled: true)])

        // B2: ownership claimed only on readback-confirmed success.
        let rec = OwnedLidAssertion(currentBootID: "boot-A", url: url).load()
        XCTAssertEqual(rec.bootID, "boot-A")
        XCTAssertTrue(rec.ownedEnabled)
        XCTAssertEqual(rec.referenceState, "on")
    }

    func testSetOnOnBackendFailureDoesNotClaimOwnership() {
        let url = makeTempURL()
        let fake = FakeLidAssertion()
        fake.observedPrior = false
        fake.nextNativeRC = 99
        var svc = makeService(prior: false, mutator: fake, storeURL: url)

        let r = svc.setEnabled(true)
        guard case .failure(let err) = r else {
            return XCTFail("expected failure, got \(r)")
        }
        XCTAssertEqual(err, .backendFailed(message: "fake: rc=99"))

        // B2: failure → no ownership claim, no persistence write.
        let rec = OwnedLidAssertion(currentBootID: "boot-A", url: url).load()
        XCTAssertFalse(rec.ownedEnabled, "failure must not produce a phantom ownership record")
    }

    func testSetOnRefusedWhenAlreadyOn() {
        let url = makeTempURL()
        let fake = FakeLidAssertion()
        fake.observedPrior = true
        var svc = makeService(prior: true, mutator: fake, storeURL: url)

        let r = svc.setEnabled(true)
        guard case .failure(let err) = r else {
            return XCTFail("expected failure, got \(r)")
        }
        XCTAssertEqual(err, .noChangeRequested(target: true))
        XCTAssertTrue(fake.calls.isEmpty, "mutator must NOT be invoked for a no-op")
    }

    // MARK: — Set OFF path (B2 ownership required)

    func testSetOffRefusedWhenWeDoNotOwn() {
        let url = makeTempURL()
        let fake = FakeLidAssertion()
        fake.observedPrior = true
        var svc = makeService(prior: true, mutator: fake, storeURL: url)
        // No pre-existing ownership record — we don't own the flag.

        let r = svc.setEnabled(false)
        guard case .failure(let err) = r else {
            return XCTFail("expected failure, got \(r)")
        }
        XCTAssertEqual(err, .notOwned)
        XCTAssertTrue(fake.calls.isEmpty,
                       "mutator must NOT be invoked when we don't own the flag (B2)")
    }

    func testSetOffSucceedsAndReleasesOwnershipWhenWeOwn() {
        let url = makeTempURL()
        // Pre-seed ownership.
        let store = OwnedLidAssertion(currentBootID: "boot-A", url: url)
        store.save(.init(bootID: "boot-A", ownedEnabled: true, referenceState: "on"))

        let fake = FakeLidAssertion()
        fake.observedPrior = true
        fake.readbackAfterWrite = false
        var svc = makeService(prior: true, mutator: fake, storeURL: url)

        let r = svc.setEnabled(false)
        guard case .success(let op) = r else {
            return XCTFail("expected success, got \(r)")
        }
        XCTAssertEqual(op.state, .verified)

        // Ownership released to reflect the restore.
        let rec = OwnedLidAssertion(currentBootID: "boot-A", url: url).load()
        XCTAssertEqual(rec.bootID, "boot-A")
        XCTAssertFalse(rec.ownedEnabled, "successful restore must release ownership")
        XCTAssertEqual(rec.referenceState, "off")
    }

    // MARK: — Restore-on-launch (B3)

    func testRestoreIfOwnedNoOpsWhenNothingOwned() {
        let url = makeTempURL()
        let fake = FakeLidAssertion()
        var svc = makeService(prior: false, mutator: fake, storeURL: url)

        let didRestore = svc.restoreIfOwned()
        XCTAssertFalse(didRestore)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testRestoreIfOwnedPerformsRestoreWhenOwned() {
        let url = makeTempURL()
        // Pre-seed ownership.
        let store = OwnedLidAssertion(currentBootID: "boot-A", url: storeURL(url))
        store.save(.init(bootID: "boot-A", ownedEnabled: true, referenceState: "on"))

        let fake = FakeLidAssertion()
        // The prior provider will be called inside setEnabled(false) → B1 guard
        // needs observedPrior == true to pass. Wire it that way.
        fake.observedPrior = true
        fake.readbackAfterWrite = false
        var svc = LidMutationService(
            bootID: "boot-A",
            mutator: fake,
            store: store,
            priorProvider: { true }
        )

        let didRestore = svc.restoreIfOwned()
        XCTAssertTrue(didRestore)
        XCTAssertEqual(fake.calls, [FakeLidAssertion.Call(enabled: false)],
                        "restore must call mutator exactly once with enabled=false")
    }

    // MARK: — Helpers

    private func storeURL(_ url: URL) -> URL { url }
}
