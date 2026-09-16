import XCTest
@testable import RunClosedHelperSupport

/// A14 registration/status skeleton tests — driven by a fake registrar so
/// every `SMAppService` state transition is pinned WITHOUT a signed bundle
/// or user approval (the live path is NOT_TESTED until the app is packaged
/// and signed with a real Apple identity, per ADR 016).
final class HelperLifecycleTests: XCTestCase {

    private final class FakeRegistrar: DaemonRegistrar, @unchecked Sendable {
        var current: DaemonStatus = .notRegistered
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0
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

    /// Descriptor invariants: plist name, binary name and daemon label are
    /// fixed points the plist template and code share.
    func testDescriptorIdentityIsStable() {
        XCTAssertEqual(RunClosedHelperDescriptor.plistName,
                       "com.benjaminbelaga.runclosed.helper.plist")
        XCTAssertEqual(RunClosedHelperDescriptor.helperBinaryName,
                       "runclosed-privileged-helper")
        XCTAssertEqual(RunClosedHelperDescriptor.daemonLabel,
                       "com.benjaminbelaga.runclosed.helper")
    }
}
