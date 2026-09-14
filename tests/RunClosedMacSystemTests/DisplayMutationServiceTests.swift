import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// Service-level tests with a controllable fake mutator and a temp-file
/// OwnedDisabledDisplays store. Mirrors the Python main.py B3 invariants.
final class DisplayMutationServiceTests: XCTestCase {

    /// Fake mutator — captures calls and lets the test drive success/failure.
    /// By default it reports `.verified` on success (matches a happy-path backend);
    /// tests can flip `nextNativeRC` to force a failure, or `failNextReadback`
    /// to make the service's own belt-and-braces readback disagree.
    private final class FakeDisplayMutator: DisplayMutator, @unchecked Sendable {
        struct Call: Equatable {
            let displayID: UInt32
            let enabled: Bool
        }
        private(set) var calls: [Call] = []
        var nextNativeRC: Int32 = 0      // what the synthetic SLS call returns
        var failNextReadback: Bool = false   // if true, the fake reports verified but service's own readback will fail

        func setEnabled(_ displayID: UInt32, _ enabled: Bool) -> OperationResult {
            calls.append(Call(displayID: displayID, enabled: enabled))
            if nextNativeRC != 0 {
                return OperationResult(
                    requestID: UUID().uuidString,
                    action: .deactivate,
                    state: .failed,
                    nativeRC: Int(nextNativeRC),
                    readbackOK: false,
                    error: "fake: rc=\(nextNativeRC)"
                )
            }
            // Default: the API succeeded AND the readback verified the new state.
            // (Tests that need the service's belt-and-braces readback to fail
            // set failNextReadback = true and adjust activeIDsProvider.)
            return OperationResult(
                requestID: UUID().uuidString,
                action: .deactivate,
                state: .verified,
                nativeRC: 0,
                readbackOK: true
            )
        }
    }

    private func makeTempURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("runclosed-dms-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("owned_displays.json")
    }

    private func makeService(
        activeIDs: [UInt32],
        mutator: FakeDisplayMutator,
        storeURL: URL,
        bootID: String = "boot-A"
    ) -> DisplayMutationService {
        let store = OwnedDisabledDisplays(currentBootID: bootID, url: storeURL)
        return DisplayMutationService(
            bootID: bootID,
            mutator: mutator,
            store: store,
            activeIDsProvider: { activeIDs }
        )
    }

    // MARK: — Disable path

    func testDisableRefusedOnLastActiveDisplay() throws {
        let url = try makeTempURL()
        let fake = FakeDisplayMutator()
        var svc = makeService(activeIDs: [42], mutator: fake, storeURL: url)

        let result = svc.disable(target: 42)
        XCTAssertEqual(result, .failure(.lastActiveDisplay(id: 42)))
        XCTAssertTrue(fake.calls.isEmpty, "mutator must NOT be invoked on refusal")
    }

    func testDisableRefusedOnStaleTarget() throws {
        let url = try makeTempURL()
        let fake = FakeDisplayMutator()
        var svc = makeService(activeIDs: [1, 2], mutator: fake, storeURL: url)

        let result = svc.disable(target: 99)
        XCTAssertEqual(result, .failure(.staleTarget(id: 99)))
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testDisableOnSuccessPersistsOwnership() throws {
        let url = try makeTempURL()
        let fake = FakeDisplayMutator()
        var svc = makeService(activeIDs: [1, 2], mutator: fake, storeURL: url)

        let result = svc.disable(target: 2)
        guard case .success(let r) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(r.state, .verified)

        // Verify the ownership record was written
        let rec = OwnedDisabledDisplays(currentBootID: "boot-A", url: url).load()
        XCTAssertEqual(rec.bootID, "boot-A")
        XCTAssertEqual(rec.ids, [2])
    }

    func testDisableOnBackendFailureDoesNotPersistOwnership() throws {
        let url = try makeTempURL()
        let fake = FakeDisplayMutator()
        fake.nextNativeRC = 99
        var svc = makeService(activeIDs: [1, 2], mutator: fake, storeURL: url)

        let result = svc.disable(target: 2)
        guard case .failure(let err) = result else {
            return XCTFail("expected failure, got \(result)")
        }
        XCTAssertEqual(err, .backendFailed(message: "fake: rc=99"))

        // No persistence on backend failure
        let rec = OwnedDisabledDisplays(currentBootID: "boot-A", url: url).load()
        XCTAssertTrue(rec.ids.isEmpty)
    }

    // MARK: — Enable path

    func testEnableRefusesUnknownTarget() throws {
        let url = try makeTempURL()
        let fake = FakeDisplayMutator()
        var svc = makeService(activeIDs: [1, 2], mutator: fake, storeURL: url)

        let result = svc.enable(target: 99)
        XCTAssertEqual(result, .failure(.unknownTarget(id: 99)))
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testEnableAcceptsOwnedTargetEvenIfNotCurrentlyActive() throws {
        let url = try makeTempURL()
        // Pre-seed the ownership record with a display that is NOT in the
        // currently active set (it was disabled last run, we're recovering).
        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)
        store.save(.init(bootID: "boot-A", ids: [42]))

        let fake = FakeDisplayMutator()
        var svc = makeService(activeIDs: [1, 2], mutator: fake, storeURL: url)

        let result = svc.enable(target: 42)
        guard case .success = result else {
            return XCTFail("expected success re-enabling owned id, got \(result)")
        }

        // The owned-id was successfully re-enabled → removed from record
        let rec = OwnedDisabledDisplays(currentBootID: "boot-A", url: url).load()
        XCTAssertTrue(rec.ids.isEmpty,
                       "successful re-enable must clear the id from the owned record")
    }

    // MARK: — Launch recovery (B3)

    func testRestoreOwnedPersistsOnlyStillOwnedIDs() throws {
        let url = try makeTempURL()
        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)
        store.save(.init(bootID: "boot-A", ids: [10, 20, 30]))

        // All API calls succeed (fake reports verified), but the service's
        // own belt-and-braces readback (via activeIDsProvider) shows only
        // [1, 2] — none of 10/20/30 are in there → the service marks each as
        // failed and retains them in the owned record.
        let fake = FakeDisplayMutator()
        fake.failNextReadback = true
        var svc = makeService(activeIDs: [1, 2], mutator: fake, storeURL: url)

        let stillOwned = svc.restoreOwned()
        XCTAssertEqual(stillOwned.sorted(), [10, 20, 30],
                       "all three should be retained because the service's own readback found them missing")

        // Record rewritten from the OUTCOME (B3): only failed ids retained.
        let rec = OwnedDisabledDisplays(currentBootID: "boot-A", url: url).load()
        XCTAssertEqual(rec.ids.sorted(), [10, 20, 30])
    }

    func testRestoreOwnedClearsSuccessfullyReEnabledIDs() throws {
        let url = try makeTempURL()
        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)
        store.save(.init(bootID: "boot-A", ids: [10]))

        // The fake reports verified + the service's readback agrees (10 is in active).
        let fake = FakeDisplayMutator()
        var svc = makeService(activeIDs: [10], mutator: fake, storeURL: url)

        let stillOwned = svc.restoreOwned()
        XCTAssertEqual(stillOwned, [], "successful re-enable clears the owned record")

        let rec = OwnedDisabledDisplays(currentBootID: "boot-A", url: url).load()
        XCTAssertTrue(rec.ids.isEmpty)
    }

    func testRestoreOwnedDiscardsStaleBootRecord() throws {
        let url = try makeTempURL()
        let store = OwnedDisabledDisplays(currentBootID: "boot-A", url: url)
        // Seed with a record from a DIFFERENT boot — stale, must be discarded.
        store.save(.init(bootID: "boot-OTHER", ids: [10, 20]))

        let fake = FakeDisplayMutator()
        var svc = makeService(activeIDs: [10, 20], mutator: fake, storeURL: url)

        let stillOwned = svc.restoreOwned()
        XCTAssertEqual(stillOwned, [],
                       "stale-boot owned records must be discarded, not re-enabled blindly")

        // The new record is empty + bootID-correct
        let rec = OwnedDisabledDisplays(currentBootID: "boot-A", url: url).load()
        XCTAssertEqual(rec.bootID, "boot-A")
        XCTAssertTrue(rec.ids.isEmpty)
    }
}
