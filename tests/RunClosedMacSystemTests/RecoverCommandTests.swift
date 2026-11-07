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

    /// The binary under test: the freshly built one when present, else the one
    /// inside the assembled bundle (CI builds both). Skipped — never silently
    /// passed — when neither exists.
    private static func cliURL() throws -> URL {
        let bin = repoRoot.appendingPathComponent(".build/out/Products/Debug/runclosed")
        if FileManager.default.isExecutableFile(atPath: bin.path) { return bin }
        let bundled = repoRoot.appendingPathComponent("build/RunClosed.app/Contents/MacOS/runclosed-cli")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        throw XCTSkip("runclosed binary not built yet — `swift build` produces it")
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
        }
    }

    // MARK: — The fast path, in-process on fakes

    private final class FakeLid: LidAssertion, @unchecked Sendable {
        var calls: [Bool] = []
        let flag: Flags
        init(_ flag: Flags) { self.flag = flag }
        func setEnabled(_ enabled: Bool) -> OperationResult {
            calls.append(enabled)
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
            appIsAlive: { false },
            wallClock: { Date(timeIntervalSince1970: 1_800_000_000) })
        return (service, lid, sleeper)
    }

    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-recover-\(UUID().uuidString)", isDirectory: true)
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
}
