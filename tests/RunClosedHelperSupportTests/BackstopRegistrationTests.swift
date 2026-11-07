import XCTest
import ServiceManagement
@testable import RunClosedHelperSupport

/// ADR 024 — the backstop agent's registration surface, driven by a fake
/// registrar so every `SMAppService` state is pinned WITHOUT a signed bundle,
/// a user approval gesture, or a real background item.
final class BackstopRegistrationTests: XCTestCase {

    private final class FakeRegistrar: BackstopRegistrar, @unchecked Sendable {
        var current: BackstopStatus = .notFound
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0
        private(set) var openLoginItemsCalls = 0
        var registerShouldFail = false
        /// The operator's explicit opt-out (`backstop unregister`).
        var optedOut = false

        func operatorOptedOut() -> Bool { optedOut }
        func setOperatorOptedOut(_ value: Bool) { optedOut = value }

        func status() -> BackstopStatus { current }
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
        func openLoginItemsSettings() { openLoginItemsCalls += 1 }
    }

    // MARK: — Every SMAppService state maps to a surfaced state

    /// The mapper is the single place a framework status becomes our state, so
    /// no state can be handled live and forgotten in the fake-driven tests.
    func testEverySMAppServiceStatusMapsToASurfacedState() {
        XCTAssertEqual(SMAppServiceAgentRegistrar.map(.notRegistered), .notRegistered)
        XCTAssertEqual(SMAppServiceAgentRegistrar.map(.enabled), .enabled)
        XCTAssertEqual(SMAppServiceAgentRegistrar.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(SMAppServiceAgentRegistrar.map(.notFound), .notFound)
    }

    /// `unknown` is a real state for a status this build does not know — it is
    /// never silently coerced into `enabled` (ADR 009 honesty).
    func testUnknownStatusIsSurfacedNotTreatedAsEnabled() {
        XCTAssertEqual(SMAppServiceAgentRegistrar.map(.notRegistered), .notRegistered)
        XCTAssertFalse(BackstopStatus.unknown.isProtecting)
        XCTAssertNotEqual(BackstopStatus.unknown, .enabled)
    }

    /// Every state exists, and exactly one of them means "the net is up".
    func testOnlyEnabledProtects() {
        for state in BackstopStatus.allCases {
            XCTAssertEqual(state.isProtecting, state == .enabled, "\(state)")
        }
        XCTAssertTrue(BackstopStatus.allCases.contains(.requiresApproval),
                      "a pending approval is surfaced, never dropped")
    }

    /// `requiresApproval` is the state the popup must explain: the string names
    /// the remedy the operator has to perform.
    func testRequiresApprovalSummaryNamesTheRemedy() {
        XCTAssertTrue(BackstopStatus.requiresApproval.summary.contains("System Settings"))
        XCTAssertFalse(BackstopStatus.requiresApproval.isProtecting,
                       "a pending agent enforces nothing yet")
    }

    // MARK: — Register / unregister

    /// The fresh-macOS state is `notFound` (ADR 018), so registration MUST be
    /// attempted from there; otherwise no Mac ever registers the agent.
    func testRegistrationIsAttemptedFromNotFound() {
        let fake = FakeRegistrar()
        let svc = BackstopLifecycleService(registrar: fake)
        let r = svc.registerIfNeeded()
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(r.status, .requiresApproval)
        XCTAssertEqual(r.lastOperationSucceeded, true)
    }

    /// Idempotent at launch: an agent that is already registered (or pending)
    /// is never re-registered — no loop, no fight with the user's approval.
    func testRegisterIfNeededIsIdempotent() {
        for state in [BackstopStatus.enabled, .requiresApproval] {
            let fake = FakeRegistrar()
            fake.current = state
            let svc = BackstopLifecycleService(registrar: fake)
            XCTAssertEqual(svc.registerIfNeeded().status, state)
            XCTAssertEqual(fake.registerCalls, 0, "\(state) must not be re-registered")
        }
    }

    /// A thrown/failed `register()` is surfaced as `lastOperationSucceeded ==
    /// false` and never fabricated into a state.
    func testAThrownRegisterIsSurfaced() {
        let fake = FakeRegistrar()
        fake.registerShouldFail = true
        let svc = BackstopLifecycleService(registrar: fake)
        let r = svc.registerIfNeeded()
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(r.lastOperationSucceeded, false)
        XCTAssertEqual(r.status, .notFound, "a failed register invents no state")
    }

    /// Unregistering when nothing is registered is a no-op: no launchd call, no
    /// fabricated success.
    func testUnregisterIsANoopWhenNotRegistered() {
        let fake = FakeRegistrar()
        fake.current = .notRegistered
        let svc = BackstopLifecycleService(registrar: fake)
        let r = svc.unregisterAndReport()
        XCTAssertEqual(fake.unregisterCalls, 0)
        XCTAssertNil(r.lastOperationSucceeded)
        XCTAssertEqual(r.status, .notRegistered)
    }

    func testFullLifecycle() {
        let fake = FakeRegistrar()
        let svc = BackstopLifecycleService(registrar: fake)
        XCTAssertEqual(svc.report().status, .notFound)
        XCTAssertEqual(svc.registerAndReport().status, .requiresApproval)
        fake.current = .enabled
        XCTAssertTrue(svc.report().isProtecting)
        XCTAssertEqual(svc.unregisterAndReport().status, .notRegistered)
        XCTAssertEqual(fake.unregisterCalls, 1)
    }

    // MARK: — An app launch must not undo an operator's unregister

    /// `unregister` is an explicit operator decision. The app registers at every
    /// launch from `notRegistered`, which is exactly the state an unregister
    /// leaves behind — so without the opt-out, launching the app would put the
    /// agent straight back with no prompt.
    func testAnAutomaticRegisterHonoursTheOperatorOptOut() {
        let fake = FakeRegistrar()
        fake.current = .notRegistered
        fake.optedOut = true
        let svc = BackstopLifecycleService(registrar: fake)
        let r = svc.registerIfNeeded(automatic: true)
        XCTAssertEqual(r.status, .notRegistered)
        XCTAssertEqual(fake.registerCalls, 0, "an app launch must not undo an explicit unregister")
        XCTAssertNil(r.lastOperationSucceeded)
    }

    /// The operator typing `backstop register` is asking for it back: that call
    /// clears the opt-out and registers.
    func testAnExplicitRegisterClearsTheOptOut() {
        let fake = FakeRegistrar()
        fake.current = .notRegistered
        fake.optedOut = true
        let svc = BackstopLifecycleService(registrar: fake)
        let r = svc.registerAndReport()
        XCTAssertFalse(fake.optedOut, "the operator asked for it back")
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(r.status, .requiresApproval)
    }

    /// Unregistering records the opt-out — otherwise the next launch undoes it.
    func testUnregisterRecordsTheOptOut() {
        let fake = FakeRegistrar()
        fake.current = .enabled
        let svc = BackstopLifecycleService(registrar: fake)
        _ = svc.unregisterAndReport()
        XCTAssertTrue(fake.optedOut)
        XCTAssertEqual(fake.unregisterCalls, 1)
    }

    /// A plain (non-automatic) `registerIfNeeded` is unaffected, so the CLI's
    /// behaviour never depends on the opt-out.
    func testANonAutomaticRegisterIgnoresTheOptOut() {
        let fake = FakeRegistrar()
        fake.current = .notRegistered
        fake.optedOut = true
        XCTAssertEqual(BackstopLifecycleService(registrar: fake)
            .registerIfNeeded().status, .requiresApproval)
        XCTAssertEqual(fake.registerCalls, 1)
    }

    func testOpenApprovalSettingsPerformsTheDeepLinkOnly() {
        let fake = FakeRegistrar()
        BackstopLifecycleService(registrar: fake).openApprovalSettings()
        XCTAssertEqual(fake.openLoginItemsCalls, 1)
        XCTAssertEqual(fake.registerCalls, 0)
        XCTAssertEqual(fake.unregisterCalls, 0)
    }

    /// The report tells the operator exactly what they are approving: a
    /// protective-only action and the 60 s interval.
    func testReportStatesTheBoundedAction() {
        let r = BackstopLifecycleService(registrar: FakeRegistrar()).report()
        XCTAssertEqual(r.boundedAction, RunClosedBackstopDescriptor.boundedAction)
        XCTAssertEqual(r.intervalSeconds, 60)
        XCTAssertFalse(r.boundedAction.lowercased().contains("turn lid stay-awake on"),
                       "the agent must never advertise an enabling action")
    }

    // MARK: — Descriptor and shipped plist

    func testDescriptorIdentityIsStable() {
        XCTAssertEqual(RunClosedBackstopDescriptor.plistName,
                       "com.benjaminbelaga.runclosed.backstop.plist")
        XCTAssertEqual(RunClosedBackstopDescriptor.agentLabel,
                       "com.benjaminbelaga.runclosed.backstop")
        XCTAssertEqual(RunClosedBackstopDescriptor.bundleProgramRelativePath,
                       "Contents/MacOS/runclosed-cli")
        XCTAssertEqual(RunClosedBackstopDescriptor.startInterval, 60)
        XCTAssertEqual(RunClosedBackstopDescriptor.programArguments,
                       ["runclosed-cli", "recover", "--backstop"])
    }

    /// The shipped plist and the descriptor cannot drift: Label,
    /// BundleProgram, the protective argv, the interval and the absence of
    /// `KeepAlive` are all asserted against the real file (the same discipline
    /// ADR 017 established for the daemon plist).
    func testShippedPlistMatchesTheDescriptor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RunClosedHelperSupportTests/
            .deletingLastPathComponent()   // tests/
            .deletingLastPathComponent()   // repo root
        let plistURL = root.appendingPathComponent("Resources/\(RunClosedBackstopDescriptor.plistName)")
        let data = try Data(contentsOf: plistURL)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(obj as? [String: Any])

        XCTAssertEqual(dict["Label"] as? String, RunClosedBackstopDescriptor.agentLabel)
        XCTAssertEqual(dict["BundleProgram"] as? String,
                       RunClosedBackstopDescriptor.bundleProgramRelativePath)
        XCTAssertEqual(dict["ProgramArguments"] as? [String],
                       RunClosedBackstopDescriptor.programArguments)
        XCTAssertEqual(dict["StartInterval"] as? Int,
                       RunClosedBackstopDescriptor.startInterval)
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true,
                       "registering must take effect now, not at the next interval")
        XCTAssertNil(dict["KeepAlive"],
                     "a one-shot every 60 s must never be KeepAlive (respawn loop)")
        XCTAssertNil(dict["Program"],
                     "BundleProgram is the SMAppService form; an absolute Program would "
                     + "point outside the bundle")
        XCTAssertNil(dict["MachServices"], "an agent exposes no listener")
    }

    /// The argv carries the protective subcommand: a plist that lost
    /// `--backstop` would make the agent a bare `recover`, which the CLI
    /// refuses (exit 64).
    func testTheShippedPlistArgvIsTheProtectiveCommand() {
        XCTAssertTrue(RunClosedBackstopDescriptor.programArguments.contains("--backstop"))
        XCTAssertTrue(RunClosedBackstopDescriptor.programArguments.contains("recover"))
    }
}
