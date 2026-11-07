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
        /// Whether the agent was ever seen registered — what lets the app tell
        /// a first run from a revocation made in System Settings.
        var everRegistered = false

        func operatorOptedOut() -> Bool { optedOut }
        func setOperatorOptedOut(_ value: Bool) { optedOut = value }
        func wasEverRegistered() -> Bool { everRegistered }
        func setWasEverRegistered(_ value: Bool) { everRegistered = value }

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

    /// A revocation made in System Settings → Login Items is a decision, and
    /// `SMAppService` reports it exactly like "never registered". Without the
    /// memory, the next app launch put the agent straight back — undoing, with
    /// no prompt, a choice the operator had just made on the very screen macOS
    /// provides for it (review round 8).
    func testAnAutomaticRegisterRespectsARevocationMadeInSystemSettings() {
        let fake = FakeRegistrar()
        fake.current = .notRegistered
        fake.everRegistered = true      // it WAS registered, then revoked
        let svc = BackstopLifecycleService(registrar: fake)
        let r = svc.registerIfNeeded(automatic: true)
        XCTAssertEqual(fake.registerCalls, 0, "a System Settings revocation must not be undone by a launch")
        XCTAssertEqual(r.status, .notRegistered)
    }

    /// …but a machine that never registered must still register, or the net
    /// would never exist on a fresh install. `notFound` is how macOS 26 reports
    /// that state (ADR 018).
    func testAFreshMachineStillRegistersAtLaunch() {
        let fake = FakeRegistrar()
        fake.current = .notFound
        fake.everRegistered = false
        let svc = BackstopLifecycleService(registrar: fake)
        _ = svc.registerIfNeeded(automatic: true)
        XCTAssertEqual(fake.registerCalls, 1, "a fresh machine has no decision to respect")
    }

    /// The explicit `backstop register` is the operator asking for it back, so
    /// it overrides a revocation — and it clears the opt-out only when the
    /// registration actually happened: a failed register that also erased the
    /// recorded "off" would silently re-register on the next launch.
    /// Review round 14 (WARNING): `.unknown` means "this process cannot see the
    /// agent", and `registerIfNeeded` deliberately attempts NOTHING there. That
    /// left `lastOperationSucceeded` at `nil`, which `registerAndReport` read as
    /// success: it cleared the operator's opt-out and the CLI exited 0, telling
    /// them the net was back while nothing had been done.
    func testAnExplicitRegisterThatCannotSeeTheAgentIsNotASuccess() {
        let fake = FakeRegistrar()
        fake.current = .unknown
        fake.optedOut = true
        let svc = BackstopLifecycleService(registrar: fake)
        let r = svc.registerAndReport()
        XCTAssertEqual(fake.registerCalls, 0, "an unreadable probe proves nothing to register against")
        XCTAssertEqual(r.lastOperationSucceeded, false,
                       "nil must not read as a success for an explicit register")
        XCTAssertTrue(fake.optedOut,
                      "and it must not erase the operator's recorded off")
    }

    /// A failed explicit register keeps the opt-out.
    func testAFailedExplicitRegisterKeepsTheOptOut() {
        let fake = FakeRegistrar()
        fake.current = .notRegistered
        fake.optedOut = true
        fake.registerShouldFail = true
        let svc = BackstopLifecycleService(registrar: fake)
        let r = svc.registerAndReport()
        XCTAssertEqual(r.lastOperationSucceeded, false)
        XCTAssertTrue(fake.optedOut,
                      "a register that failed must not erase the operator's recorded off")
    }

    /// A successful explicit register DOES clear it, and reports the state it
    /// now reports rather than the one from before the clear.
    func testASuccessfulExplicitRegisterClearsTheOptOutAndReportsIt() {
        let fake = FakeRegistrar()
        fake.current = .notRegistered
        fake.optedOut = true
        fake.registerShouldFail = false
        let r = BackstopLifecycleService(registrar: fake).registerAndReport()
        XCTAssertEqual(r.lastOperationSucceeded, true)
        XCTAssertFalse(fake.optedOut, "the operator asked for it back")
        XCTAssertFalse(r.operatorOptedOut, "the report must describe the state AFTER the clear")
        XCTAssertEqual(r.status, .requiresApproval)
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
    ///
    /// This feeds the mapper an actual UNRECOGNISED status: an earlier version
    /// re-asserted `.notRegistered` (already covered above), so flipping the
    /// mapper's `@unknown default` to `.enabled` would have gone unnoticed —
    /// the exact regression the name claims to guard.
    /// `SMAppService` resolves the plist against the CALLING bundle. A caller
    /// that is not RunClosed (a bare `swift run`, a copied binary) therefore
    /// sees `notFound` for an agent that IS registered — and reporting that as
    /// a definite "off" made the CLI refuse every timed session on a machine
    /// where the backstop works. The honest answer is "this process cannot
    /// see it".
    func testAnUnresolvableBundleNeverReportsTheAgentAsDefinitelyOff() {
        // The test runner's bundle id is not RunClosed's, which is exactly the
        // foreign-bundle case.
        XCTAssertNotEqual(Bundle.main.bundleIdentifier,
                          RunClosedBackstopDescriptor.appBundleIdentifier,
                          "this test is only meaningful from a foreign bundle")
        // A REAL registrar call from here must not claim `notFound`.
        XCTAssertNotEqual(SMAppServiceAgentRegistrar().status(), .notFound,
                          "a foreign bundle must read unknown, never a definite off")
    }

    func testAnUnrecognisedStatusMapsToUnknownNotEnabled() throws {
        let unrecognised = try XCTUnwrap(SMAppService.Status(rawValue: 99),
                                         "the SDK should accept an unknown raw value")
        XCTAssertEqual(SMAppServiceAgentRegistrar.map(unrecognised), .unknown)
        XCTAssertNotEqual(SMAppServiceAgentRegistrar.map(unrecognised), .enabled)
        XCTAssertFalse(BackstopStatus.unknown.isProtecting)
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

    /// The opt-out must be VISIBLE, not merely honoured. Without it the state
    /// is indistinguishable from "never registered": the app skips the
    /// registration, `status` reports `notRegistered`/`notFound`, and every
    /// surface tells the operator to approve an agent in System Settings that
    /// will never appear there. The net ADR 024 exists for then never exists,
    /// silently (review round 7).
    func testTheReportSurfacesAnOperatorOptOut() {
        let fake = FakeRegistrar()
        fake.current = .notRegistered
        fake.optedOut = true
        let r = BackstopLifecycleService(registrar: fake).report()
        XCTAssertTrue(r.operatorOptedOut,
                      "a report that hides the operator's own decision sends them to an empty Settings screen")
        // Nothing is normalized: the status stays the registry fact.
        XCTAssertEqual(r.status, .notRegistered)
        XCTAssertFalse(r.isProtecting)
    }

    /// No opt-out means no claim: a fresh machine must not read as if the
    /// operator had refused the net.
    func testAFreshMachineReportsNoOptOut() {
        let fake = FakeRegistrar()
        fake.current = .notRegistered
        XCTAssertFalse(BackstopLifecycleService(registrar: fake).report().operatorOptedOut)
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
    /// The agent must still leave a trace now that launchd no longer writes
    /// one for it: `appendAgentLog` creates the directory, appends (never
    /// truncates) and is a no-op rather than a throw on failure (review round
    /// 16).
    func testAppendAgentLogCreatesTheDirectoryAndAppends() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-agentlog-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let expected = RunClosedBackstopDescriptor.agentLogURL(home: home)
        XCTAssertTrue(expected.path.hasSuffix("/Library/Logs/RunClosed/backstop.log"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path),
                       "nothing exists before the first write")

        XCTAssertTrue(RunClosedBackstopDescriptor.prepareLogDirectory(home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.deletingLastPathComponent().path),
                      "the directory launchd refuses to create is created at runtime")

        // Two appends must both survive: the second must never truncate the
        // first, or the trace of an earlier failure disappears.
        RunClosedBackstopDescriptor.appendAgentLog("line one", home: home)
        RunClosedBackstopDescriptor.appendAgentLog("line two", home: home)
        let text = try String(contentsOf: expected, encoding: .utf8)
        XCTAssertTrue(text.contains("line one"))
        XCTAssertTrue(text.contains("line two"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

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
        // The agent MUST leave a trace — a refusal or a failed `pmset` is the
        // only place it can say WHY the net is not protecting the operator.
        //
        // But it must NOT be launchd's StandardErrorPath/StandardOutPath: those
        // are FIXED bytes in a signed bundle, so any path they name belongs to
        // the machine that built it. Installed by another account, the agent
        // would write into a directory the running user may not own, or fail
        // the open and lose its diagnostics entirely — and launchd expands no
        // variable there, so no correct value exists to substitute (review
        // rounds 13-16 flagged this every time). The agent therefore writes its
        // own trace under NSHomeDirectory() at RUNTIME, using the home of the
        // user launchd actually started it as.
        for key in ["StandardErrorPath", "StandardOutPath"] {
            XCTAssertNil(dict[key],
                         "\(key) is a build-time constant in a signed bundle: it "
                         + "names the builder's home on someone else's machine. The "
                         + "agent logs via appendAgentLog() instead")
        }
        XCTAssertTrue(dict["BundleProgram"] != nil)
    }

    /// The argv carries the protective subcommand: a plist that lost
    /// `--backstop` would make the agent a bare `recover`, which the CLI
    /// refuses (exit 64).
    func testTheShippedPlistArgvIsTheProtectiveCommand() {
        XCTAssertTrue(RunClosedBackstopDescriptor.programArguments.contains("--backstop"))
        XCTAssertTrue(RunClosedBackstopDescriptor.programArguments.contains("recover"))
    }
}
