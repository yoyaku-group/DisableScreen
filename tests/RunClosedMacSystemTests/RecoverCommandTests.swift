import XCTest
import Foundation
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// The `recover --backstop` CLI contract (ADR 024): the fast path must exit 0
/// WITHOUT touching `pmset`, a busy lock must exit 75, and the Usage errors
/// must exit 64 before anything else happens.
///
/// The tests drive the built `runclosed-cli` binary for the paths that are
/// pure usage handling, and the same `RecoveryBackstopService` wiring the CLI
/// uses (on fakes, in a temp dir) for the paths that would otherwise mutate the
/// real machine. Nothing here flips the real power flag or registers anything.
final class RecoverCommandTests: XCTestCase {

    // MARK: — Usage: exit 64, in a subprocess of the real binary

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // RunClosedMacSystemTests/
        .deletingLastPathComponent()   // tests/
        .deletingLastPathComponent()   // repo root

    /// The binary under test.
    ///
    /// Ordered by freshness, newest first: `swift build` on CI writes
    /// `.build/debug/`, Xcode's dev-script layout writes
    /// `.build/out/Products/Debug/`, and the assembled bundle is only built
    /// AFTER `swift test` (ci.yml) so it is the stalest of the three. Testing a
    /// leftover bundle before the freshly built binary would check code that is
    /// not under review.
    ///
    /// Never silently skipped in CI: a missing binary there means the coverage
    /// this file exists for vanished, so it fails instead of passing green.
    private static func cliURL() throws -> URL {
        let candidates = [
            ".build/debug/runclosed",
            ".build/out/Products/Debug/runclosed",
            "build/RunClosed.app/Contents/MacOS/runclosed-cli",
        ].map { repoRoot.appendingPathComponent($0) }
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return found
        }
        // In CI a missing binary is a FAILURE, not a skip: it means the build
        // step stopped producing it, and skipping would silently drop the
        // exit-code, status-JSON and doctor/status coverage this file exists
        // for while the run stays green. Locally it is only a skip — a
        // developer may not have built the executable yet.
        let searched = candidates.map(\.path).joined(separator: ", ")
        if ProcessInfo.processInfo.environment["CI"] != nil {
            XCTFail("CI: no runclosed binary found (looked in \(searched)) — "
                    + "`swift build --build-tests` must produce .build/debug/runclosed")
        }
        throw XCTSkip("no runclosed binary yet (looked in \(searched)) — run `swift build`")
    }

    /// Run the CLI with `args`, returning (exit code, stdout+stderr).
    @discardableResult
    private func runCLI(_ args: [String]) throws -> (rc: Int32, output: String) {
        let exe = try Self.cliURL()
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// `recover` without `--backstop` is a usage error: this command is the
    /// agent's, and a bare `recover` must never be reachable as a mutation.
    func testRecoverWithoutBackstopExits64() throws {
        let (rc, output) = try runCLI(["recover"])
        XCTAssertEqual(rc, 64, output)
        XCTAssertTrue(output.contains("--backstop"), output)
    }

    /// An unknown flag is a usage error too — `--backstop` is a fixed argv, so
    /// anything else means the caller is not the agent.
    func testRecoverWithABogusFlagExits64() throws {
        for args in [["recover", "--bogus"], ["recover", "--backstop", "--force"],
                     ["recover", "--backstop", "extra"]] {
            let (rc, output) = try runCLI(args)
            XCTAssertEqual(rc, 64, "\(args): \(output)")
        }
    }

    /// `backstop` with no subcommand, or an unknown one, is usage.
    func testBackstopUnknownSubcommandExits64() throws {
        for args in [["backstop"], ["backstop", "definitely-not-a-command"],
                     ["backstop", "status", "--bogus"], ["backstop", "register", "extra"]] {
            let (rc, output) = try runCLI(args)
            XCTAssertEqual(rc, 64, "\(args): \(output)")
        }
    }

    /// `backstop status --json` answers without registering anything: it is a
    /// READ. Every state is surfaced, and `protecting` is exactly true when the
    /// agent is enabled.
    func testBackstopStatusJSONIsReadOnlyAndSurfaced() throws {
        let (rc, output) = try runCLI(["backstop", "status", "--json"])
        XCTAssertEqual(rc, 0, output)
        guard let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backstop = obj["backstop"] as? [String: Any] else {
            return XCTFail("expected a JSON backstop block, got: \(output)")
        }
        let status = backstop["status"] as? String
        XCTAssertNotNil(status)
        XCTAssertTrue(["notRegistered", "enabled", "requiresApproval", "notFound", "unknown"]
            .contains(status ?? ""), "unexpected status \(status ?? "nil")")
        XCTAssertEqual(backstop["protecting"] as? Bool, status == "enabled")
        XCTAssertEqual(backstop["intervalSeconds"] as? Int, 60)
        XCTAssertEqual(obj["plistName"] as? String,
                       "com.benjaminbelaga.runclosed.backstop.plist")
        XCTAssertEqual(obj["programArguments"] as? [String],
                       ["runclosed-cli", "recover", "--backstop"])
    }

    /// `doctor` and `status` both carry the backstop block (ADR 024 §6): a
    /// diagnostic that stayed silent about the safety net would be a
    /// diagnostic that lies about coverage.
    func testDoctorAndStatusCarryTheBackstopBlock() throws {
        for command in ["doctor", "status"] {
            let (rc, output) = try runCLI([command])
            XCTAssertEqual(rc, 0, output)
            guard let data = output.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return XCTFail("\(command): expected JSON, got \(output)")
            }
            let backstop = try XCTUnwrap(obj["backstop"] as? [String: Any],
                                         "\(command) has no backstop block")
            XCTAssertNotNil(backstop["status"], command)
            XCTAssertNotNil(backstop["protecting"], command)
            // Round 2: registration is not proof of execution, so the blocks
            // must also say whether a run is PROVEN recent.
            //
            // Only INVARIANTS are asserted here, never this machine's state: a
            // hard-coded `recentRun == false` passes on a developer box where
            // the agent was never installed and FAILS on the deployed Mac this
            // lot ships to — the test would be measuring the machine, not the
            // code.
            XCTAssertNotNil(backstop["enforcing"], command)
            XCTAssertNotNil(backstop["recentRun"], command)
            XCTAssertNotNil(backstop["lastRunAt"], command)
            XCTAssertNotNil(backstop["lastExitCode"], command)
            XCTAssertEqual(backstop["enforcing"] as? Bool,
                           (backstop["protecting"] as? Bool == true)
                           && (backstop["recentRun"] as? Bool == true),
                           "\(command): enforcing = enabled AND a proven recent run")
            // The heartbeat fields agree with each other: a run is either
            // recorded (both fields present) or not (both null).
            let hasRun = backstop["lastRunAt"] is String
            XCTAssertEqual(hasRun, backstop["lastExitCode"] is Int,
                           "\(command): lastRunAt and lastExitCode describe the same run")
            if !(backstop["protecting"] as? Bool ?? false) {
                XCTAssertEqual(backstop["enforcing"] as? Bool, false,
                               "\(command): a backstop that is not registered cannot be enforcing")
            }
        }
    }

    // MARK: — The fast path, in-process on fakes

    private final class FakeLid: LidAssertion, @unchecked Sendable {
        var calls: [Bool] = []
        /// When true, every write reports `.failed` with no read-back — the
        /// `sudo -n` failure path.
        var failWrites = false
        let flag: Flags
        init(_ flag: Flags) { self.flag = flag }
        func setEnabled(_ enabled: Bool) -> OperationResult {
            calls.append(enabled)
            if failWrites {
                return OperationResult(requestID: "t", action: .sleepAll, state: .failed,
                                       nativeRC: 1, readbackOK: false,
                                       error: "sudo: a password is required")
            }
            flag.value = enabled
            return OperationResult(requestID: "t", action: .sleepAll, state: .verified,
                                   nativeRC: 0, readbackOK: true)
        }
    }

    private final class Flags: @unchecked Sendable { var value: Bool? }

    private final class Sleeper: SystemSleeper, @unchecked Sendable {
        var count = 0
        func sleepNow() -> (rc: Int32, output: String?) { count += 1; return (0, nil) }
    }

    private final class ClockStub: ContinuousClock, @unchecked Sendable {
        let bootID = "A"
        var nowContinuousNanoseconds: UInt64 { ContinuousClockTimebase.nanoseconds(fromSeconds: 1_000) }
    }

    /// The wiring `recover --backstop` runs, on fakes and a temp dir. This is
    /// the same composition as `RecoveryBackstopService.live`, with the real
    /// pmset/lock paths replaced.
    private func makeService(dir: URL,
                             flagOn: Bool?,
                             record: (bootID: String, owned: Bool)?,
                             alarm: Bool = false) -> (RecoveryBackstopService, FakeLid, Sleeper) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lidStore = OwnedLidAssertion(currentBootID: "A", url: dir.appendingPathComponent("owned_lid.json"))
        if let record {
            lidStore.save(.init(bootID: record.bootID, ownedEnabled: record.owned,
                                referenceState: record.owned ? "on" : "off"))
        }
        let flags = Flags()
        flags.value = flagOn
        let lid = FakeLid(flags)
        let sleeper = Sleeper()
        let clock = ClockStub()
        let sessionStore = SessionStore(url: dir.appendingPathComponent("session.json"))
        let latchStore = LowBatteryLatchStore(url: dir.appendingPathComponent("latch.json"))
        let session = SessionService(
            store: sessionStore, latchStore: latchStore, continuous: clock,
            wallClock: { Date(timeIntervalSince1970: 1_800_000_000) },
            observedFlag: { flags.value },
            ownershipRecord: {
                let rec = lidStore.load()
                return (rec.bootID, rec.ownedEnabled)
            },
            applyLid: SessionService.gatedLid(bootID: "A", makeMutator: { lid },
                                              store: lidStore,
                                              priorProvider: { flags.value }))
        let guardService = LowBatteryGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flags.value }),
            latchStore: latchStore,
            batteryProvider: {
                // Never reached on the fast path: a call here proves the
                // minute was NOT free, which the no-record test forbids.
                BatteryState(onBattery: true, chargePercent: 3, minutesRemaining: 1,
                             isCharging: false, batteryPresent: true)
            },
            sleeper: sleeper,
            lock: LidWriteLock(url: dir.appendingPathComponent("lid.lock")),
            auditLog: LowBatteryAuditLog(url: dir.appendingPathComponent("low_battery_audit.jsonl")),
            sessionService: session)
        let service = RecoveryBackstopService(
            sessionService: session,
            guardService: guardService,
            lock: LidWriteLock(url: dir.appendingPathComponent("lid.lock")),
            auditLog: RecoveryAuditLog(url: dir.appendingPathComponent("recovery_audit.jsonl")),
            // MUST be injected: the default is the real
            // `~/Library/Application Support/RunClosed/backstop_heartbeat.json`,
            // and a test that wrote there would forge proof of execution on the
            // developer's machine.
            heartbeatStore: BackstopHeartbeatStore(
                url: dir.appendingPathComponent("backstop_heartbeat.json")),
            appIsAlive: { false },
            wallClock: { Date(timeIntervalSince1970: 1_800_000_000) })
        return (service, lid, sleeper)
    }

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-recover-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// No ownership record and no session: exit 0, and NOTHING was called —
    /// not `pmset`, not the battery readback, not the sleeper. This is the
    /// assertion that the 60 s minute is free.
    func testFastPathExits0WithoutAnySystemCall() {
        var (service, lid, sleeper) = makeService(dir: tempDir(), flagOn: nil, record: nil)
        XCTAssertEqual(service.run().exitCode.rawValue, 0)
        XCTAssertTrue(lid.calls.isEmpty, "the fast path must not call pmset")
        XCTAssertEqual(sleeper.count, 0)
    }

    /// A record that has released the flag is not a claim: still free.
    func testAReleasedRecordIsStillTheFastPath() {
        var (service, lid, _) = makeService(dir: tempDir(), flagOn: false,
                                            record: ("A", false))
        XCTAssertEqual(service.run().exitCode.rawValue, 0)
        XCTAssertTrue(lid.calls.isEmpty)
    }

    /// Busy lock → 75, the launchd "retry next minute" convention.
    func testBusyLockExits75() {
        let dir = tempDir()
        var (service, lid, sleeper) = makeService(dir: dir, flagOn: true, record: ("A", true))
        let other = LidWriteLock(url: dir.appendingPathComponent("lid.lock"))
        let rc = other.tryWithLock { service.run().exitCode.rawValue }
        XCTAssertEqual(rc, 75)
        XCTAssertTrue(lid.calls.isEmpty)
        XCTAssertEqual(sleeper.count, 0)
    }

    // MARK: — No test may touch the real Application Support directory

    /// Regression: a fixture that forgets to inject the heartbeat store writes
    /// to the developer's REAL `RunClosed/backstop_heartbeat.json`, forging
    /// proof of execution on the machine — a safety record must never be
    /// produced by a test. The fixture above injects it; this pins the intent.
    /// Checking only that the URLs differ is not enough: a service that ignored
    /// the injected store and wrote BOTH would pass. The real path's existence
    /// and mtime are captured before the run and must be unchanged after it.
    func testTheFixtureNeverWritesTheRealHeartbeatPath() throws {
        let real = BackstopHeartbeatStore().url
        let before = (try? FileManager.default.attributesOfItem(atPath: real.path))?[.modificationDate] as? Date
        let existedBefore = FileManager.default.fileExists(atPath: real.path)

        let dir = tempDir()
        var (service, _, _) = makeService(dir: dir, flagOn: nil, record: nil)
        _ = service.run()

        let injected = dir.appendingPathComponent("backstop_heartbeat.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: injected.path),
                      "the run wrote to the injected store")
        XCTAssertNotEqual(service.heartbeatStore.url, real,
                          "a test must never share the production heartbeat path")

        let after = (try? FileManager.default.attributesOfItem(atPath: real.path))?[.modificationDate] as? Date
        XCTAssertEqual(FileManager.default.fileExists(atPath: real.path), existedBefore,
                       "the real heartbeat path must not be created by a test")
        XCTAssertEqual(after, before, "the real heartbeat file must not be touched by a test")
    }

    // MARK: — The exit-code map, through the REAL renderer

    /// `renderRecover` is what the LaunchAgent's argv actually runs, so the
    /// mapping is asserted here rather than only on the service: a test that
    /// proves `Report.exitCode` while the CLI prints something else proves
    /// nothing about the agent.

    /// One `describe` call, so the exit code and the JSON come from the same
    /// outcome — asserting them on two separate runs would let them drift.
    private func render(_ service: inout RecoveryBackstopService) -> (rc: Int32, json: [String: Any]) {
        let d = RecoveryBackstopService.describe(service.run(), bootID: "A")
        return (d.exitCode, d.json)
    }

    /// Battery release verified → 0, JSON says released.
    func testReleasedBatteryStepExits0ThroughTheRecoverCommand() throws {
        var (service, lid, sleeper) = makeService(dir: tempDir(), flagOn: true, record: ("A", true))
        let out = render(&service)
        XCTAssertEqual(out.rc, 0)
        XCTAssertEqual(out.json["outcome"] as? String, "completed")
        XCTAssertEqual(out.json["exitCode"] as? Int, 0)
        XCTAssertEqual(out.json["batteryMutation"] as? String, "released")
        XCTAssertEqual(out.json["batteryReason"] as? String, "criticalOwned")
        XCTAssertEqual(out.json["sleepAttempted"] as? Bool, true)
        XCTAssertEqual(lid.calls, [false], "the release happened")
        XCTAssertEqual(sleeper.count, 1, "a verified release is followed by sleepnow")
    }

    /// A failing battery release → 5. This is the round-2 fix: it used to
    /// report success while the Mac stayed awake at critical battery.
    func testFailedBatteryReleaseExits5ThroughTheRecoverCommand() {
        var (service, lid, _) = makeService(dir: tempDir(), flagOn: true, record: ("A", true))
        lid.failWrites = true
        let out = render(&service)
        XCTAssertEqual(out.rc, 5, "a protective action that did not happen is not a success")
        XCTAssertEqual(out.json["exitCode"] as? Int, 5)
        XCTAssertEqual(out.json["batteryMutation"] as? String, "releaseFailed")
        XCTAssertNotNil(out.json["batteryError"] as? String)
        XCTAssertEqual(lid.calls, [false], "the release was attempted")
    }

    /// Battery step absent (fast path) → 0, and no battery fields invented.
    func testFastPathExits0ThroughTheRecoverCommand() {
        var (service, _, _) = makeService(dir: tempDir(), flagOn: nil, record: nil)
        let out = render(&service)
        XCTAssertEqual(out.rc, 0)
        XCTAssertEqual(out.json["outcome"] as? String, "nothingToDo")
        XCTAssertEqual(out.json["exitCode"] as? Int, 0)
    }

    /// Busy → 75 through the same rendering path, so launchd's retry contract
    /// holds for the command it actually invokes.
    func testBusyExits75ThroughTheRecoverCommand() {
        let dir = tempDir()
        var (service, _, _) = makeService(dir: dir, flagOn: true, record: ("A", true))
        let other = LidWriteLock(url: dir.appendingPathComponent("lid.lock"))
        let out = other.tryWithLock { render(&service) }
        XCTAssertEqual(out?.rc, 75)
        XCTAssertEqual(out?.json["outcome"] as? String, "busy")
        XCTAssertEqual(out?.json["exitCode"] as? Int, 75)
    }
}
