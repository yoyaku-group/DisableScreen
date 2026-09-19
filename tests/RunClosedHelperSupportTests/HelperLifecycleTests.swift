import XCTest
@testable import RunClosedHelperSupport

/// A14 registration/status skeleton tests — driven by a fake registrar so
/// every `SMAppService` state transition is pinned WITHOUT a signed bundle
/// or user approval (per ADR 016/017; the live path is exercised by the
/// packaging script + bundled CLI on a real .app).
final class HelperLifecycleTests: XCTestCase {

    private final class FakeRegistrar: DaemonRegistrar, @unchecked Sendable {
        var current: DaemonStatus = .notRegistered
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0
        private(set) var openLoginItemsCalls = 0
        var registerShouldFail = false

        func status() -> DaemonStatus { current }
        func register() -> Bool {
            registerCalls += 1
            if registerShouldFail { return false }
            current = .requiresApproval   // the NORMAL post-register state
            return true
        }
        func unregister() -> Bool {
            unregisterCalls += 1
            current = .notRegistered
            return true
        }
        func openLoginItemsSettings() {
            openLoginItemsCalls += 1
        }
    }

    /// requiresApproval is an EXPECTED state, surfaced — never normalized
    /// to enabled, never swallowed.
    func testRequiresApprovalIsSurfacedNotSwallowed() {
        let fake = FakeRegistrar()
        fake.current = .requiresApproval
        let svc = HelperLifecycleService(registrar: fake)
        XCTAssertEqual(svc.report().status, .requiresApproval)
    }

    /// notFound is a real broken state, distinct from notRegistered — a
    /// moved bundle must never read as "clean slate".
    func testNotFoundIsDistinctFromNotRegistered() {
        let fake = FakeRegistrar()
        fake.current = .notFound
        let svc = HelperLifecycleService(registrar: fake)
        let r = svc.report()
        XCTAssertEqual(r.status, .notFound)
        XCTAssertNotEqual(r.status, .notRegistered)
    }

    /// registerAndReport only registers from notRegistered — an existing
    /// registration (any other state) is not re-registered.
    func testRegisterOnlyFromNotRegistered() {
        let fake = FakeRegistrar()
        fake.current = .enabled
        let svc = HelperLifecycleService(registrar: fake)
        XCTAssertEqual(svc.registerAndReport().status, .enabled)
        XCTAssertEqual(fake.registerCalls, 0, "must not re-register an already-registered daemon")
    }

    func testRegisterAndReportNormalPathLeadsToRequiresApproval() {
        let fake = FakeRegistrar()
        let svc = HelperLifecycleService(registrar: fake)
        let r = svc.registerAndReport()
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(r.status, .requiresApproval,
                       "post-register, the user approval gate is the expected state")
    }

    /// Honesty fields: the report names the ONE bounded operation and
    /// states plainly that XPC is not implemented in this tranche.
    func testReportIsHonestAboutBoundedOperationAndXPC() {
        let svc = HelperLifecycleService(registrar: FakeRegistrar())
        let r = svc.report()
        XCTAssertEqual(r.boundedOperation,
                       "/usr/bin/pmset -a disablesleep <0|1>",
                       "the daemon must advertise exactly its one allowed operation")
        XCTAssertFalse(r.xpcImplemented, "this tranche has no XPC — the report must say so")
    }

    /// Full lifecycle cycle (the E2E microcosm): notRegistered → register →
    /// requiresApproval → (user approves → enabled) → unregister →
    /// notRegistered. Pins the exact sequence the live qualification cycle
    /// demonstrates.
    func testFullLifecycleCycle() {
        let fake = FakeRegistrar()
        let svc = HelperLifecycleService(registrar: fake)

        XCTAssertEqual(svc.report().status, .notRegistered)

        let afterRegister = svc.registerAndReport()
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(afterRegister.status, .requiresApproval)
        XCTAssertEqual(afterRegister.lastOperationSucceeded, true)

        fake.current = .enabled          // the user approved it in System Settings
        XCTAssertEqual(svc.report().status, .enabled)

        let afterUnregister = svc.unregisterAndReport()
        XCTAssertEqual(fake.unregisterCalls, 1)
        XCTAssertEqual(afterUnregister.status, .notRegistered)
        XCTAssertEqual(afterUnregister.lastOperationSucceeded, true)
    }

    /// macOS 26 daemon reality (observed 2026-09-17): a never-registered
    /// daemon reads `notFound`, not `notRegistered` — registration must
    /// still be attempted from there, or a fresh machine could never
    /// register.
    func testRegisterProceedsFromNotFound() {
        let fake = FakeRegistrar()
        fake.current = .notFound
        let svc = HelperLifecycleService(registrar: fake)
        let r = svc.registerAndReport()
        XCTAssertEqual(fake.registerCalls, 1,
                       "notFound pre-registration must attempt register (macOS 26)")
        XCTAssertEqual(r.status, .requiresApproval)
    }

    /// A pending approval is a state to surface, never to fight — no
    /// register retry loop.
    func testRegisterNoopWhenRequiresApproval() {
        let fake = FakeRegistrar()
        fake.current = .requiresApproval
        let svc = HelperLifecycleService(registrar: fake)
        XCTAssertEqual(svc.registerAndReport().status, .requiresApproval)
        XCTAssertEqual(fake.registerCalls, 0,
                       "a pending approval must not be re-registered in a loop")
    }

    /// unregister with nothing registered is a no-op — no launchd call, no
    /// fabricated success.
    func testUnregisterNoopWhenNotRegistered() {
        let fake = FakeRegistrar()
        let svc = HelperLifecycleService(registrar: fake)
        let r = svc.unregisterAndReport()
        XCTAssertEqual(fake.unregisterCalls, 0)
        XCTAssertEqual(r.status, .notRegistered)
        XCTAssertNil(r.lastOperationSucceeded)
    }

    /// A failing register() is surfaced (`lastOperationSucceeded == false`),
    /// never swallowed into a bare status.
    func testRegisterFailureIsSurfaced() {
        let fake = FakeRegistrar()
        fake.registerShouldFail = true
        let svc = HelperLifecycleService(registrar: fake)
        let r = svc.registerAndReport()
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(r.lastOperationSucceeded, false)
        XCTAssertEqual(r.status, .notRegistered, "a failed register must not fabricate a state")
    }

    /// The approval deep link is a first-class registrar call (the CLI
    /// `helper login-items` path) — and it performs no privileged work.
    func testOpenApprovalSettingsRecordsCall() {
        let fake = FakeRegistrar()
        let svc = HelperLifecycleService(registrar: fake)
        svc.openApprovalSettings()
        XCTAssertEqual(fake.openLoginItemsCalls, 1)
    }

    /// P1 regression (ADR 017): the shipped plist must use `BundleProgram`
    /// with the descriptor's bundle-relative path and must NOT contain the
    /// legacy absolute `Program` key nor a `MachServices` listener.
    func testShippedPlistUsesBundleProgramRelativePath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RunClosedHelperSupportTests/
            .deletingLastPathComponent()   // tests/
            .deletingLastPathComponent()   // repo root
        let plistURL = root.appendingPathComponent("Resources/\(RunClosedHelperDescriptor.plistName)")
        let data = try Data(contentsOf: plistURL)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(obj as? [String: Any])

        XCTAssertEqual(dict["Label"] as? String, RunClosedHelperDescriptor.daemonLabel)
        XCTAssertEqual(dict["BundleProgram"] as? String,
                       RunClosedHelperDescriptor.bundleProgramRelativePath,
                       "plist BundleProgram must match the descriptor (ADR 017)")
        XCTAssertNil(dict["Program"],
                     "absolute Program belongs to the deprecated SMJobBless flow — must be absent")
        XCTAssertNil(dict["MachServices"],
                     "T1 ships no listener surface — MachServices arrives with T2")
        XCTAssertNil(dict["KeepAlive"],
                     "T1 daemon never runs — no KeepAlive until XPC lands")
        XCTAssertNil(dict["RunAtLoad"],
                     "T1 daemon never runs — registration skeleton only")
    }

    /// Descriptor invariants: plist name, binary name, bundle-relative
    /// program path and daemon label are fixed points the plist template,
    /// the packaging script and the code share.
    func testDescriptorIdentityIsStable() {
        XCTAssertEqual(RunClosedHelperDescriptor.plistName,
                       "com.benjaminbelaga.runclosed.helper.plist")
        XCTAssertEqual(RunClosedHelperDescriptor.helperBinaryName,
                       "runclosed-privileged-helper")
        XCTAssertEqual(RunClosedHelperDescriptor.bundleProgramRelativePath,
                       "Contents/MacOS/runclosed-privileged-helper")
        XCTAssertEqual(RunClosedHelperDescriptor.daemonLabel,
                       "com.benjaminbelaga.runclosed.helper")
    }
}
