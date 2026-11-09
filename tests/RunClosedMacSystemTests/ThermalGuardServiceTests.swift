import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// The thermal guard driven end to end on fakes (ADR 025): a fake lid, a fake
/// sleeper, injected thermal/clamshell/display readings and temp-dir stores.
/// Nothing here touches the real power flag, the real thermal state or `pmset`.
final class ThermalGuardServiceTests: XCTestCase {

    // MARK: — Fakes

    private final class FakeLid: LidAssertion, @unchecked Sendable {
        var calls: [Bool] = []
        var failWrites = false
        let flag: FlagBox
        init(flag: FlagBox) { self.flag = flag }
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

    private final class FlagBox: @unchecked Sendable {
        var value: Bool?
        init(_ v: Bool?) { value = v }
    }

    /// Captures what the guard told the operator, so a test can assert on the
    /// announcement itself instead of inferring it from a boolean.
    private final class LineBox: @unchecked Sendable {
        private(set) var all: [String] = []
        func append(_ line: String) { all.append(line) }
    }

    private final class FakeSleeper: SystemSleeper, @unchecked Sendable {
        var count = 0
        var rc: Int32 = 0
        func sleepNow() -> (rc: Int32, output: String?) {
            count += 1
            return (rc, nil)
        }
    }

    /// Runs a side effect at the exact moment the release asks the Mac to
    /// sleep — i.e. between the pre-sleep latch write and the trailing one in
    /// `step()`.
    private final class BreakingSleeper: SystemSleeper, @unchecked Sendable {
        private(set) var count = 0
        private let onSleep: () -> Void
        init(_ onSleep: @escaping () -> Void) { self.onSleep = onSleep }
        func sleepNow() -> (rc: Int32, output: String?) {
            count += 1
            onSleep()
            return (0, nil)
        }
    }

    /// One box for the whole observable world, so a test walks the machine
    /// through states with a single assignment.
    private final class World: @unchecked Sendable {
        var state: ThermalState
        var lidClosed: Bool?
        var externalDisplay: Bool?
        /// The monotonic clock the guard reads.
        var now: Double
        init(state: ThermalState = .nominal, lidClosed: Bool? = true,
             externalDisplay: Bool? = false, now: Double = 1_000) {
            self.state = state
            self.lidClosed = lidClosed
            self.externalDisplay = externalDisplay
            self.now = now
        }
    }

    private struct Rig {
        var service: ThermalGuardService
        let lid: FakeLid
        let sleeper: FakeSleeper
        let flag: FlagBox
        let world: World
        let lidStore: OwnedLidAssertion
        let latchStore: ThermalLatchStore
        let audit: ThermalAuditLog
    }

    /// - `ownedBoot`: nil = no record, "A" = owned on this boot, "OLD" = stale.
    private func makeRig(state: ThermalState = .nominal,
                         lidClosed: Bool? = true,
                         externalDisplay: Bool? = false,
                         flag: Bool? = true,
                         ownedBoot: String? = "A",
                         now: Double = 1_000) -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The grid test builds dozens of rigs; without this every run leaves
        // files behind.
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let lidStore = OwnedLidAssertion(currentBootID: "A",
                                         url: dir.appendingPathComponent("owned_lid.json"))
        if let b = ownedBoot {
            lidStore.save(.init(bootID: b, ownedEnabled: true, referenceState: "on"))
        }
        let flagBox = FlagBox(flag)
        let lid = FakeLid(flag: flagBox)
        let sleeper = FakeSleeper()
        let world = World(state: state, lidClosed: lidClosed,
                          externalDisplay: externalDisplay, now: now)
        let latchStore = ThermalLatchStore(url: dir.appendingPathComponent("thermal_guard.json"))
        let audit = ThermalAuditLog(url: dir.appendingPathComponent("thermal_audit.jsonl"))
        let service = ThermalGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: latchStore,
            thermalProvider: { world.state },
            lidClosedProvider: { world.lidClosed },
            externalDisplayProvider: { world.externalDisplay },
            monotonic: { world.now },
            sleeper: sleeper,
            auditLog: audit)
        return Rig(service: service, lid: lid, sleeper: sleeper, flag: flagBox, world: world,
                   lidStore: lidStore, latchStore: latchStore, audit: audit)
    }

    // MARK: — The release paths

    func testCriticalEnclosedOwnedReleasesThenSleeps() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "A")
        let out = rig.service.step()

        XCTAssertEqual(out.evaluation.decision.action, .releaseAndSleep)
        XCTAssertEqual(out.mutation, .released)
        XCTAssertEqual(rig.lid.calls, [false], "disablesleep 0 through the gated path")
        XCTAssertEqual(rig.sleeper.count, 1, "and then the Mac is asked to sleep")
        XCTAssertTrue(out.sleepAttempted)
        XCTAssertEqual(out.notice, .releasedCritical)
        XCTAssertTrue(out.shouldNotify)
        XCTAssertTrue(rig.latchStore.load().latch.releasedForHeat,
                      "the latch is written from the OUTCOME, after a verified release")
        XCTAssertFalse(rig.flag.value ?? true, "the flag really is off")
    }

    func testSeriousSustainedReleases() {
        var rig = makeRig(state: .serious, flag: true, ownedBoot: "A", now: 1_000)
        let first = rig.service.step()
        XCTAssertEqual(first.evaluation.decision.action, .warn)
        XCTAssertEqual(first.notice, .seriousHeadsUp)
        XCTAssertEqual(rig.lid.calls, [], "the grace period writes nothing")

        // Nine minutes later: still nothing.
        rig.world.now = 1_000 + 9 * 60
        let nine = rig.service.step()
        XCTAssertNil(nine.mutation)
        XCTAssertEqual(nine.evaluation.decision.action, .none)
        XCTAssertEqual(rig.lid.calls, [])

        // Ten minutes: release + sleep.
        rig.world.now = 1_000 + 10 * 60
        let ten = rig.service.step()
        XCTAssertEqual(ten.evaluation.decision.action, .releaseAndSleep)
        XCTAssertEqual(ten.evaluation.decision.reason, .seriousSustained)
        XCTAssertEqual(ten.mutation, .released)
        XCTAssertEqual(rig.lid.calls, [false])
        XCTAssertEqual(rig.sleeper.count, 1)
        XCTAssertEqual(ten.notice, .releasedSustained)
    }

    func testNominalDoesNothing() {
        var rig = makeRig(state: .nominal, flag: true, ownedBoot: "A")
        let out = rig.service.step()
        XCTAssertEqual(out.evaluation.decision.action, .none)
        XCTAssertNil(out.mutation)
        XCTAssertEqual(rig.lid.calls, [])
        XCTAssertEqual(rig.sleeper.count, 0)
        XCTAssertTrue(rig.audit.load().isEmpty, "no audit line on a minute without effect")
    }

    func testFairDoesNothingEither() {
        var rig = makeRig(state: .fair, flag: true, ownedBoot: "A")
        let out = rig.service.step()
        XCTAssertEqual(out.evaluation.decision.action, .none)
        XCTAssertNil(out.mutation)
    }

    // MARK: — Critical heat, flag not ours (B2)

    /// A critical temperature on a flag that is not ours authorizes NO write:
    /// alert only. Asserted on the fake's call log, not on the outcome enum.
    func testCriticalHeatOnAForeignFlagWritesNothing() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: nil)
        let out = rig.service.step()

        XCTAssertEqual(out.evaluation.decision.action, .warn)
        XCTAssertEqual(out.evaluation.decision.reason, .notOwned)
        XCTAssertNil(out.mutation)
        XCTAssertEqual(rig.lid.calls, [], "B2: never mutate a flag we do not own")
        XCTAssertEqual(rig.sleeper.count, 0)
        XCTAssertEqual(rig.flag.value, true, "the flag is untouched")
        XCTAssertEqual(out.notice, .releaseRefused)
    }

    /// A stale record of ours is not active ownership for the heat rule.
    func testCriticalHeatOnAStaleRecordWritesNothing() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "OLD")
        let out = rig.service.step()
        XCTAssertNil(out.mutation)
        XCTAssertEqual(rig.lid.calls, [])
        XCTAssertEqual(rig.sleeper.count, 0)
    }

    // MARK: — Critical heat, lid open / display attached

    func testCriticalHeatWithTheLidOpenWritesNothing() {
        var rig = makeRig(state: .critical, lidClosed: false, flag: true, ownedBoot: "A")
        let out = rig.service.step()
        XCTAssertEqual(out.evaluation.decision.reason, .lidOpen)
        XCTAssertNil(out.mutation)
        XCTAssertEqual(rig.lid.calls, [], "the air circulates: no write")
        XCTAssertEqual(rig.sleeper.count, 0)
        // The operator is still TOLD — critical heat is worth saying even when
        // the guard may not act on it.
        XCTAssertEqual(out.evaluation.decision.action, .warn)
        XCTAssertTrue(out.shouldNotify)
        XCTAssertEqual(out.notice, .releaseRefused)
    }

    func testCriticalHeatWithAnExternalDisplayWritesNothing() {
        var rig = makeRig(state: .critical, externalDisplay: true, flag: true, ownedBoot: "A")
        let out = rig.service.step()
        XCTAssertEqual(out.evaluation.decision.reason, .externalDisplay)
        XCTAssertNil(out.mutation)
        XCTAssertEqual(rig.lid.calls, [])
        XCTAssertEqual(rig.sleeper.count, 0)
    }

    /// Unknown is not `false`: an unreadable clamshell or display refuses.
    func testUnreadableReadingsNeverRelease() {
        for (lid, external) in [(nil, false), (true, nil), (nil, nil)] as [(Bool?, Bool?)] {
            var rig = makeRig(state: .critical, lidClosed: lid,
                              externalDisplay: external, flag: true, ownedBoot: "A")
            _ = rig.service.step()
            XCTAssertEqual(rig.lid.calls, [],
                           "lid=\(String(describing: lid)) ext=\(String(describing: external)) must not release")
            XCTAssertEqual(rig.sleeper.count, 0)
        }
    }

    // MARK: — Failures

    func testAFailedReleaseIsReportedAndKeepsTheLatchClear() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "A")
        rig.lid.failWrites = true
        let out = rig.service.step()
        XCTAssertEqual(out.mutation, .releaseFailed)
        XCTAssertEqual(out.notice, .releaseFailed)
        XCTAssertTrue(out.shouldNotify)
        XCTAssertFalse(rig.latchStore.load().latch.releasedForHeat,
                       "a release that did not take is not recorded as one")
        XCTAssertEqual(rig.sleeper.count, 0, "a failed release does not ask for sleep here")
    }

    /// A `pmset sleepnow` that refuses is visible to the caller instead of
    /// being swallowed: the release happened, the sleep did not.
    func testASleepRefusalIsVisible() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "A")
        rig.sleeper.rc = 1
        let out = rig.service.step()
        XCTAssertEqual(out.mutation, .released)
        XCTAssertEqual(out.sleepRC, 1)
    }

    // MARK: — The warning paths

    func testSeriousHeadsUpIsNotifiedOncePerEpisode() {
        var rig = makeRig(state: .serious, flag: true, ownedBoot: "A")
        let first = rig.service.step()
        XCTAssertEqual(first.notice, .seriousHeadsUp)
        XCTAssertTrue(first.shouldNotify)
        let second = rig.service.step()
        XCTAssertFalse(second.shouldNotify, "never every 30 s")
        XCTAssertNil(second.notice)
    }

    func testSeriousNotOwnedIsNotifiedOnce() {
        var rig = makeRig(state: .serious, flag: true, ownedBoot: nil)
        let first = rig.service.step()
        XCTAssertEqual(first.notice, .seriousNotProtected)
        XCTAssertTrue(first.shouldNotify)
        let second = rig.service.step()
        XCTAssertFalse(second.shouldNotify)
    }

    // MARK: — The audit trail

    /// One line per ACTION: a release writes one, a no-op minute writes none.
    func testTheAuditTrailGetsOneLinePerAction() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "A")
        let out = rig.service.step()
        let lines = rig.audit.load()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.outcome, "released")
        XCTAssertEqual(lines.first?.reason, "criticalOwned")
        XCTAssertEqual(lines.first?.thermalState, "critical")
        XCTAssertEqual(lines.first?.lid, "closed")
        XCTAssertEqual(lines.first?.externalDisplay, "none")
        XCTAssertEqual(lines.first?.ownership, "ownedThisBoot")
        // The line is written AFTER the sleep attempt, so it carries what
        // `pmset sleepnow` actually answered. A post-mortem of an overheat has
        // to be able to tell "the flag was released and the Mac slept" from
        // "the flag was released and the Mac stayed awake" — a nil there made
        // the field useless. The LATCH is still persisted before the call
        // (journal before change), because state and record are not the same
        // thing: one must survive the sleep, the other must describe it.
        XCTAssertEqual(lines.first?.sleepRC, 0)
        XCTAssertEqual(out.sleepRC, 0)
    }

    /// And when the sleep is REFUSED, that is what the line says: the release
    /// happened, the Mac did not sleep, and the audit must not read as success.
    func testTheAuditLineCarriesARefusedSleep() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "A")
        rig.sleeper.rc = 1
        let out = rig.service.step()
        XCTAssertEqual(out.mutation, .released)
        let line = rig.audit.load().first
        XCTAssertEqual(line?.outcome, "released")
        XCTAssertEqual(line?.sleepRC, 1, "a refused sleepnow is recorded as such")
    }

    /// A heat refusal that holds must not write a line every 30 s: 2 880
    /// identical lines a day is exactly the flood the "one line per action"
    /// rule exists to prevent. The latch carries the dedupe.
    func testARepeatingRefusalIsAuditedOncePerEpisode() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: nil)
        let first = rig.service.step()
        XCTAssertTrue(first.shouldNotify)
        XCTAssertEqual(rig.audit.load().count, 1, "the first refusal of the episode is recorded")
        for _ in 0..<5 { _ = rig.service.step() }
        XCTAssertEqual(rig.audit.load().count, 1, "the repeats are silent")

        // The machine cools and heats up again: a NEW episode, so it speaks —
        // and records — again.
        rig.world.state = .nominal
        _ = rig.service.step()
        rig.world.state = .critical
        let again = rig.service.step()
        XCTAssertTrue(again.shouldNotify)
        XCTAssertEqual(rig.audit.load().count, 2)
    }

    func testANominalMinuteWritesNoAuditLine() {
        var rig = makeRig(state: .nominal, flag: true, ownedBoot: "A")
        for _ in 0..<5 { _ = rig.service.step() }
        XCTAssertTrue(rig.audit.load().isEmpty)
    }

    /// A warn mutates nothing but it IS an action — the operator is told — so
    /// it earns exactly one line for the episode, not one per tick.
    func testAHeadsUpWritesOneLinePerEpisode() {
        var rig = makeRig(state: .serious, flag: true, ownedBoot: "A")
        _ = rig.service.step()
        XCTAssertEqual(rig.audit.load().count, 1)
        XCTAssertEqual(rig.audit.load().first?.outcome, "none",
                       "nothing was written to the flag")
        XCTAssertEqual(rig.audit.load().first?.reason, "seriousWarn")
        for _ in 0..<5 { _ = rig.service.step() }
        XCTAssertEqual(rig.audit.load().count, 1, "the repeats say nothing")
    }

    // MARK: — Latch survives a restart

    /// The latch is what keeps the alert once-per-episode across a process
    /// restart: a fresh `ThermalGuardService` over the same store must NOT
    /// re-alert and must NOT restart the grace period.
    func testTheLatchSurvivesARestartAndDoesNotReAlert() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-restart-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let lidURL = dir.appendingPathComponent("owned_lid.json")
        let latchURL = dir.appendingPathComponent("thermal_guard.json")
        let flagBox = FlagBox(true)
        let lid = FakeLid(flag: flagBox)
        let sleeper = FakeSleeper()
        let world = World(state: .serious, lidClosed: true, externalDisplay: false, now: 1_000)
        let lidStore = OwnedLidAssertion(currentBootID: "A", url: lidURL)
        lidStore.save(.init(bootID: "A", ownedEnabled: true, referenceState: "on"))

        func make() -> ThermalGuardService {
            ThermalGuardService(
                lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                               priorProvider: { flagBox.value }),
                latchStore: ThermalLatchStore(url: latchURL),
                thermalProvider: { world.state },
                lidClosedProvider: { world.lidClosed },
                externalDisplayProvider: { world.externalDisplay },
                monotonic: { world.now },
                sleeper: sleeper,
                auditLog: ThermalAuditLog(url: dir.appendingPathComponent("thermal_audit.jsonl")))
        }

        var first = make()
        let warned = first.step()
        XCTAssertEqual(warned.notice, .seriousHeadsUp)
        XCTAssertTrue(warned.shouldNotify)

        // New process, same store: the alert is not repeated.
        var second = make()
        let afterRestart = second.step()
        XCTAssertFalse(afterRestart.shouldNotify, "the latch remembered the alert")
        XCTAssertNil(afterRestart.notice)

        // And the grace period was NOT restarted: it trips at 10 min from the
        // ORIGINAL start, not from the relaunch.
        world.now = 1_000 + 10 * 60
        let released = second.step()
        XCTAssertEqual(released.evaluation.decision.action, .releaseAndSleep)
        XCTAssertEqual(released.evaluation.latchBefore.seriousSince, 1_000,
                       "the counter kept its original start across the restart")
        XCTAssertEqual(lid.calls, [false])
    }

    /// `releasedForHeat` also survives: after a relaunch the bar can still say
    /// the session ended for heat, and it clears once the machine cools.
    func testReleasedForHeatSurvivesARestartAndClearsOnCooling() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "A")
        _ = rig.service.step()
        XCTAssertTrue(rig.latchStore.load().latch.releasedForHeat)

        // Relaunch: the store is the only memory, and it still says heat.
        let world = rig.world
        let lidStore = rig.lidStore
        let flagBox = rig.flag
        let sleeper = rig.sleeper
        let latchStore = rig.latchStore
        var relaunched = ThermalGuardService(
            lidService: LidMutationService(bootID: "A", mutator: rig.lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: latchStore,
            thermalProvider: { world.state },
            lidClosedProvider: { world.lidClosed },
            externalDisplayProvider: { world.externalDisplay },
            monotonic: { world.now },
            sleeper: sleeper,
            auditLog: rig.audit)
        XCTAssertTrue(relaunched.evaluate().latchBefore.releasedForHeat)

        // The machine cools: the episode is over and the signal clears.
        world.state = .nominal
        _ = relaunched.step()
        XCTAssertFalse(latchStore.load().latch.releasedForHeat)
    }

    // MARK: — The sweep

    /// Over the whole grid the guard reads, it never issues an `enable`. Same
    /// shape as the ADR 024 sweep, and the reason `ThermalPolicy.Action` has no
    /// enable case at all.
    func testTheThermalGuardNeverEnablesTheFlag() {
        let states = ThermalState.allCases
        for state in states {
            for lid in [true, false, nil] as [Bool?] {
                for external in [true, false, nil] as [Bool?] {
                    for flag in [true, false, nil] as [Bool?] {
                        for ownedBoot in ["A", "OLD", nil] as [String?] {
                            var rig = makeRig(state: state, lidClosed: lid,
                                              externalDisplay: external, flag: flag,
                                              ownedBoot: ownedBoot)
                            _ = rig.service.step()
                            XCTAssertFalse(
                                rig.lid.calls.contains(true),
                                "an enable was issued for state=\(state) lid=\(String(describing: lid)) ext=\(String(describing: external)) flag=\(String(describing: flag)) owned=\(String(describing: ownedBoot))")
                        }
                    }
                }
            }
        }
    }

    // MARK: — Lock discipline

    /// The thermal step runs on the CALLER's lock section — that is the whole
    /// ADR 025 invariant. This test proves `ThermalGuardService.step()` takes
    /// no lock at all: it is called here with nobody holding `LidWriteLock`,
    /// and it returns. A nested `withLock` would deadlock, so the wait fails by
    /// name after 10 s instead of hanging.
    func testTheThermalStepDoesNotNestTheWriteLock() {
        let rig = makeRig(state: .critical, flag: true, ownedBoot: "A")
        final class Run: @unchecked Sendable {
            var service: ThermalGuardService
            var outcome: ThermalGuardService.TickOutcome?
            let done: XCTestExpectation
            init(_ s: ThermalGuardService, _ e: XCTestExpectation) { service = s; done = e }
        }
        let run = Run(rig.service, expectation(description: "thermal step returns"))
        Thread { run.outcome = run.service.step(); run.done.fulfill() }.start()
        guard XCTWaiter().wait(for: [run.done], timeout: 10) == .completed else {
            return XCTFail("the thermal step did not return: LidWriteLock is nested (deadlock)")
        }
        XCTAssertEqual(run.outcome?.mutation, .released)
    }

    /// The other half: the guard's shared tick holds the section for the whole
    /// thermal step. Proven by a probe that tries a NON-blocking acquisition
    /// from another fd while the thermal release runs — it must fail.
    func testTheSharedTickHoldsTheLockDuringTheThermalStep() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-lock-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let lockURL = dir.appendingPathComponent("lid.lock")
        let lidStore = OwnedLidAssertion(currentBootID: "A",
                                         url: dir.appendingPathComponent("owned_lid.json"))
        lidStore.save(.init(bootID: "A", ownedEnabled: true, referenceState: "on"))
        let flagBox = FlagBox(true)
        let lid = FakeLid(flag: flagBox)
        let sleeper = FakeSleeper()
        let other = LidWriteLock(url: lockURL)
        final class Seen: @unchecked Sendable { var outside: [Bool] = [] }
        let seen = Seen()

        // The probe point: the thermal readback runs INSIDE the section.
        let thermal = ThermalGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: ThermalLatchStore(url: dir.appendingPathComponent("thermal_guard.json")),
            thermalProvider: {
                seen.outside.append(other.tryWithLock { 1 } == nil)
                return .critical
            },
            lidClosedProvider: { true },
            externalDisplayProvider: { false },
            monotonic: { 1_000 },
            sleeper: sleeper,
            auditLog: ThermalAuditLog(url: dir.appendingPathComponent("thermal_audit.jsonl")))
        var service = LowBatteryGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: LowBatteryLatchStore(url: dir.appendingPathComponent("latch.json")),
            batteryProvider: { .unknown },
            sleeper: sleeper,
            lock: LidWriteLock(url: lockURL),
            auditLog: LowBatteryAuditLog(url: dir.appendingPathComponent("low_battery_audit.jsonl")),
            thermalService: thermal)
        _ = service.tick()

        XCTAssertFalse(seen.outside.isEmpty, "the thermal step ran")
        XCTAssertTrue(seen.outside.allSatisfy { $0 }, "the section is exclusive")
        XCTAssertEqual(other.tryWithLock { 2 }, 2, "and released afterwards")
    }

    // MARK: — Settings

    func testTheThermalGuardDefaultsToEnabled() {
        // A defaults domain with no key at all: absent = enabled.
        let suite = "runclosed-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        XCTAssertTrue(ThermalGuardSettings.isEnabled(defaults: defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    func testTheKillSwitchTurnsItOff() {
        let suite = "runclosed-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: ThermalGuardSettings.enabledKey)
        XCTAssertFalse(ThermalGuardSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: ThermalGuardSettings.enabledKey)
        XCTAssertTrue(ThermalGuardSettings.isEnabled(defaults: defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    func testANilDefaultsReadsAsEnabled() {
        XCTAssertTrue(ThermalGuardSettings.isEnabled(defaults: nil))
    }

    func testTheTwoGuardsUseDifferentKeys() {
        XCTAssertEqual(ThermalGuardSettings.enabledKey, "thermalGuardEnabled")
        XCTAssertNotEqual(ThermalGuardSettings.enabledKey, LowBatteryGuardSettings.enabledKey,
                          "two kill switches, not one")
        XCTAssertEqual(ThermalGuardSettings.suiteName, LowBatteryGuardSettings.suiteName,
                       "same defaults domain")
    }

    // MARK: — The thermal-only tick (battery guard switched off)

    /// With the battery guard killed, the app still runs the thermal step in
    /// the SAME section as the session step — and never the battery one. That
    /// is the only way the two kill switches stay independent in both
    /// directions.
    func testTheThermalOnlyTickRunsHeatAndSessionButNotBattery() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-only-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let lidStore = OwnedLidAssertion(currentBootID: "A",
                                         url: dir.appendingPathComponent("owned_lid.json"))
        lidStore.save(.init(bootID: "A", ownedEnabled: true, referenceState: "on"))
        let flagBox = FlagBox(true)
        let lid = FakeLid(flag: flagBox)
        let sleeper = FakeSleeper()
        let world = World(state: .critical, lidClosed: true, externalDisplay: false)
        // Critical battery TOO: if the battery step ran, it would release as
        // well (and it must not — the operator switched it off).
        let service = ThermalGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: ThermalLatchStore(url: dir.appendingPathComponent("thermal_guard.json")),
            thermalProvider: { world.state },
            lidClosedProvider: { world.lidClosed },
            externalDisplayProvider: { world.externalDisplay },
            monotonic: { world.now },
            sleeper: sleeper,
            auditLog: ThermalAuditLog(url: dir.appendingPathComponent("thermal_audit.jsonl")))
        var batteryGuard = LowBatteryGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: LowBatteryLatchStore(url: dir.appendingPathComponent("latch.json")),
            batteryProvider: {
                BatteryState(onBattery: true, chargePercent: 3, minutesRemaining: 2,
                             isCharging: false, batteryPresent: true)
            },
            sleeper: sleeper,
            lock: LidWriteLock(url: dir.appendingPathComponent("lid.lock")),
            auditLog: LowBatteryAuditLog(url: dir.appendingPathComponent("lb.jsonl")),
            thermalService: service)
        let outcome = batteryGuard.thermalTick()

        XCTAssertFalse(outcome.batteryStepRan, "the caller must not announce a battery action")
        XCTAssertEqual(outcome.thermal?.mutation, .released)
        XCTAssertEqual(lid.calls, [false], "exactly one write: the heat release")
        XCTAssertEqual(sleeper.count, 1)
    }

    /// The thermal-only tick with nothing hot is silent: no mutation, no
    /// notice, and still no battery decision.
    func testTheThermalOnlyTickIsInertWhenTheMachineIsCool() {
        let rig = makeRig(state: .nominal, flag: true, ownedBoot: "A")
        var batteryGuard = LowBatteryGuardService(
            lidService: rig.service.lidService,
            latchStore: LowBatteryLatchStore(
                url: rig.latchStore.url.deletingLastPathComponent()
                    .appendingPathComponent("latch.json")),
            batteryProvider: {
                BatteryState(onBattery: true, chargePercent: 3, minutesRemaining: 2,
                             isCharging: false, batteryPresent: true)
            },
            sleeper: rig.sleeper,
            lock: LidWriteLock(url: rig.latchStore.url.deletingLastPathComponent()
                .appendingPathComponent("lid.lock")),
            auditLog: LowBatteryAuditLog(url: rig.audit.url.deletingLastPathComponent()
                .appendingPathComponent("lb.jsonl")),
            thermalService: rig.service)
        let outcome = batteryGuard.thermalTick()
        XCTAssertFalse(outcome.batteryStepRan)
        XCTAssertNil(outcome.mutation, "a critical battery is not acted on with the guard off")
        XCTAssertEqual(rig.lid.calls, [])
        XCTAssertEqual(rig.sleeper.count, 0)
    }

    // MARK: — A latch that cannot be written

    /// The failure mode this guard cannot afford to swallow.
    ///
    /// `seriousSince` lives in the latch file, so a save that fails makes every
    /// tick look like the FIRST tick of an episode: the ten-minute clock
    /// restarts forever and `.seriousSustained` NEVER fires. The guard goes on
    /// looking healthy while being completely inert. So the store reports it,
    /// and the service surfaces it on the outcome.
    func testAFailedLatchWriteIsReportedNotSwallowed() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-latchfail-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // A latch path whose PARENT is a regular file: any write under it
        // fails with ENOTDIR, which is a genuine I/O failure rather than a
        // permission trick that root could bypass.
        let blocker = dir.appendingPathComponent("blocker")
        try? Data("not a directory".utf8).write(to: blocker)
        let unwritable = blocker.appendingPathComponent("nested/thermal_guard.json")

        let lidStore = OwnedLidAssertion(currentBootID: "A",
                                         url: dir.appendingPathComponent("owned_lid.json"))
        lidStore.save(.init(bootID: "A", ownedEnabled: true, referenceState: "on"))
        let flagBox = FlagBox(true)
        let lid = FakeLid(flag: flagBox)
        let sleeper = FakeSleeper()
        let world = World(state: .serious, lidClosed: true, externalDisplay: false)
        var service = ThermalGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: ThermalLatchStore(url: unwritable),
            thermalProvider: { world.state },
            lidClosedProvider: { world.lidClosed },
            externalDisplayProvider: { world.externalDisplay },
            monotonic: { world.now },
            sleeper: sleeper,
            auditLog: ThermalAuditLog(url: dir.appendingPathComponent("thermal_audit.jsonl")))

        // A `serious` tick mutates the latch (warnedSerious + seriousSince), so
        // it is exactly the tick whose save can fail.
        let out = service.step()
        XCTAssertTrue(out.latchSaveFailed, "a latch write that failed must say so")
        XCTAssertEqual(out.evaluation.decision.action, .warn)

        // The store itself reports it too — the service is not guessing.
        XCTAssertFalse(ThermalLatchStore(url: unwritable).save(.init(latch: .init())))
    }

    /// The complementary case, so the flag means something: a normal write is
    /// NOT reported as a failure.
    func testASuccessfulLatchWriteIsNotFlagged() {
        var rig = makeRig(state: .serious, flag: true, ownedBoot: "A")
        let out = rig.service.step()
        XCTAssertFalse(out.latchSaveFailed)
    }

    /// A release persists the latch twice in one tick: once before
    /// `pmset sleepnow` for durability, then again at the end of `step()`. Only
    /// the first may warn, otherwise the one line an operator actually needs
    /// appears twice for a single condition.
    ///
    /// Captured through the injected `warn` sink, so this fails if someone
    /// drops `announce: false` from the `step()` call — the regression it
    /// exists to catch is the duplicate line, not the outcome flag.
    func testAReleasePersistsTwiceAndOnlyTheFirstAnnounces() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-announce-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // A latch path that cannot be written, so BOTH writes of the release
        // tick fail and each one would speak if the throttle were missing.
        let blocker = dir.appendingPathComponent("blocker")
        try? Data("not a directory".utf8).write(to: blocker)
        let unwritable = blocker.appendingPathComponent("nested/thermal_guard.json")

        let lidStore = OwnedLidAssertion(currentBootID: "A",
                                         url: dir.appendingPathComponent("owned_lid.json"))
        lidStore.save(.init(bootID: "A", ownedEnabled: true, referenceState: "on"))
        let flagBox = FlagBox(true)
        let sleeper = FakeSleeper()
        let world = World(state: .critical, lidClosed: true, externalDisplay: false)
        let lines = LineBox()
        var service = ThermalGuardService(
            lidService: LidMutationService(bootID: "A", mutator: FakeLid(flag: flagBox),
                                           store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: ThermalLatchStore(url: unwritable),
            thermalProvider: { world.state },
            lidClosedProvider: { world.lidClosed },
            externalDisplayProvider: { world.externalDisplay },
            monotonic: { world.now },
            sleeper: sleeper,
            auditLog: ThermalAuditLog(url: dir.appendingPathComponent("thermal_audit.jsonl")),
            warn: { lines.append($0) })

        let out = service.step()
        XCTAssertTrue(out.latchSaveFailed, "the latch cannot be written in this rig")

        let latchLines = lines.all.filter { $0.contains("latch could NOT be written") }
        XCTAssertEqual(latchLines.count, 1,
                       "a release writes the latch twice; the warning must appear once. "
                       + "Got \(latchLines.count): \(latchLines)")
    }

    /// `announce: false` must never turn a NEW failure into silence. It only
    /// suppresses a repeat: the first write of the tick spoke, so the second
    /// has nothing to add.
    ///
    /// The scenario under test is precisely "first write succeeds, second
    /// fails". `performRelease` writes the latch, calls `attemptSleep`, and
    /// `step()` writes it again afterwards — so the sleeper is the seam between
    /// the two writes. This fake makes the latch file unwritable exactly when
    /// the sleep is attempted, which is after the first write landed and before
    /// the second one starts.
    func testTheSecondWriteOfAReleaseStillReportsFailureSilently() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-silent-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        addTeardownBlock { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let latchURL = dir.appendingPathComponent("thermal_guard.json")
        let lidStore = OwnedLidAssertion(currentBootID: "A",
                                         url: dir.appendingPathComponent("owned_lid.json"))
        lidStore.save(.init(bootID: "A", ownedEnabled: true, referenceState: "on"))
        let flagBox = FlagBox(true)
        let world = World(state: .critical, lidClosed: true, externalDisplay: false)
        let lines = LineBox()
        // Withdraw write permission on the directory the moment the release
        // asks for sleep: the pre-sleep write has already landed, the trailing
        // write in `step()` has not started.
        let releaser = BreakingSleeper { [dir] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o555],
                                                   ofItemAtPath: dir.path)
        }
        var service = ThermalGuardService(
            lidService: LidMutationService(bootID: "A", mutator: FakeLid(flag: flagBox),
                                           store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: ThermalLatchStore(url: latchURL),
            thermalProvider: { world.state },
            lidClosedProvider: { world.lidClosed },
            externalDisplayProvider: { world.externalDisplay },
            monotonic: { world.now },
            sleeper: releaser,
            auditLog: ThermalAuditLog(url: dir.appendingPathComponent("thermal_audit.jsonl")),
            warn: { lines.append($0) })

        let out = service.step()

        XCTAssertEqual(releaser.count, 1, "the release must have attempted the sleep")
        XCTAssertTrue(out.latchSaveFailed,
                      "the trailing write failed, so the flag must describe it")
        XCTAssertEqual(lines.all.filter { $0.contains("latch could NOT be written") }.count, 1,
                       "nothing spoke before this failure, so the operator must be told once")
    }

    /// The consequence, stated as a test: with the latch unwritable the
    /// sustained release can never be reached, because the clock restarts on
    /// every tick. This is why the failure has to be loud.
    func testAnUnwritableLatchMakesTheSustainedReleaseUnreachable() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-thermal-inert-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let blocker = dir.appendingPathComponent("blocker")
        try? Data("not a directory".utf8).write(to: blocker)
        let unwritable = blocker.appendingPathComponent("nested/thermal_guard.json")

        let lidStore = OwnedLidAssertion(currentBootID: "A",
                                         url: dir.appendingPathComponent("owned_lid.json"))
        lidStore.save(.init(bootID: "A", ownedEnabled: true, referenceState: "on"))
        let flagBox = FlagBox(true)
        let lid = FakeLid(flag: flagBox)
        let sleeper = FakeSleeper()
        let world = World(state: .serious, lidClosed: true, externalDisplay: false, now: 1_000)
        var service = ThermalGuardService(
            lidService: LidMutationService(bootID: "A", mutator: lid, store: lidStore,
                                           priorProvider: { flagBox.value }),
            latchStore: ThermalLatchStore(url: unwritable),
            thermalProvider: { world.state },
            lidClosedProvider: { world.lidClosed },
            externalDisplayProvider: { world.externalDisplay },
            monotonic: { world.now },
            sleeper: sleeper,
            auditLog: ThermalAuditLog(url: dir.appendingPathComponent("thermal_audit.jsonl")))

        // Walk well past the grace period, one tick at a time.
        for minute in stride(from: 0, through: 30, by: 5) {
            world.now = 1_000 + Double(minute) * 60
            let out = service.step()
            XCTAssertTrue(out.latchSaveFailed, "every tick fails to persist")
            XCTAssertNil(out.mutation, "and nothing is ever released (minute \(minute))")
        }
        XCTAssertEqual(lid.calls, [],
                       "the silent-inert failure this flag exists to expose")
        XCTAssertEqual(sleeper.count, 0)
    }

    // MARK: — Round 6: a historical obligation must not disable heat protection

    private struct NoDeviceAudio: AudioOutputBackend {
        func readDefaultOutput() -> AudioOutputSnapshot? { nil }
        func readOutput(uid: String) -> AudioOutputSnapshot? { nil }
        func setMuted(_ muted: Bool, uid: String) -> Bool { false }
    }

    private struct NoProcesses: ProcessPauseBackend {
        func runningProcesses(matching appNames: [String]) -> ProcessScan? { ProcessScan(targets: []) }
        func identity(ofPid pid: Int32) -> LidCloseActionJournal.ProcessIdentity? { nil }
        func stop(pid: Int32) -> Bool { false }
        func resume(pid: Int32) -> Bool { false }
        func isStopped(pid: Int32) -> Bool? { nil }
    }

    /// A HISTORICAL obligation must not veto thermal protection: an unplugged
    /// headset stranded in `unverifiedAudio` used to block every
    /// critical-temperature release forever (gate finding, `Historical recovery
    /// obligations indefinitely veto thermal protection`).
    func testHistoricalAudioObligationDoesNotVetoThermalRelease() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "A")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("veto-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let journal = LidCloseActionJournal(url: dir.appendingPathComponent("j.json"))
        // An obligation with NO live effect: nothing muted, nothing stopped.
        journal.save(.init(unverifiedAudio: [.init(
            deviceUID: "GoneHeadset", wasMuted: false, volume: 0.5)]))

        var actions = LidCloseActionService(
            journal: journal,
            auditLog: LidCloseActionAuditLog(url: dir.appendingPathComponent("a.jsonl")),
            audio: NoDeviceAudio(), processes: NoProcesses(), bootID: "A")
        actions.stopConfirmDelay = {}
        rig.service.lidCloseActions = actions

        let out = rig.service.step()

        XCTAssertEqual(out.mutation, .released,
                       "a historical obligation disabled the thermal protection")
    }



    /// The thermal sleep path runs the lid-close undo a SECOND time after the
    /// first was incomplete. That pass can resume a process the first left
    /// unconfirmed, and keeping only the first result dropped the newly resumed
    /// pid, the `changed` signal and any notice — a report that reads like a
    /// clean recovery over a Mac that still has an app frozen (gate finding,
    /// `Second thermal undo result is discarded`).
    ///
    /// Counter-proof: with the old `if outcome.lidCloseUndo == nil` guard the
    /// resumed pid below is absent and the assertion fails.
    func testTheSecondThermalUndoIsMergedNotDiscarded() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "A")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("merge-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // A process WE stopped, whose resume fails until the FIFTH attempt.
        //
        // The ledger: the three vetoed ticks each run one undo (attempts 1-3);
        // the tick that exhausts the budget runs the pre-release undo (4,
        // still refused) and then `attemptSleep`'s undo (5, which takes). So
        // the pid only ever appears in the SECOND pass of the releasing tick —
        // exactly the case `if lidCloseUndo == nil` used to drop.
        let processes = FlakyResumeProcesses(pid: 4711, succeedsOn: 5)
        let journal = LidCloseActionJournal(url: dir.appendingPathComponent("j.json"))
        journal.save(.init(stopped: [.init(
            pid: 4711, startSeconds: 1_700_000_000, startMicroseconds: 0,
            bootID: "A", path: "/Applications/Slack.app/Contents/MacOS/Slack",
            appName: "Slack")]))

        var actions = LidCloseActionService(
            journal: journal,
            auditLog: LidCloseActionAuditLog(url: dir.appendingPathComponent("a.jsonl")),
            audio: NoDeviceAudio(), processes: processes, bootID: "A")
        actions.stopConfirmDelay = {}
        rig.service.lidCloseActions = actions

        // Enough refusals to exhaust the veto budget, then the release proceeds.
        for _ in 0..<ThermalGuardService.maximumLidCloseVetoes {
            _ = rig.service.step()
        }
        let out = rig.service.step()

        XCTAssertEqual(out.mutation, .released)
        XCTAssertEqual(out.lidCloseUndo?.resumedPids, [4711],
                       "the process the SECOND undo resumed is missing from the report")
        XCTAssertEqual(out.lidCloseUndo?.changed, true,
                       "the report claims nothing changed while an app was resumed")
    }

    /// A process that refuses the first `SIGCONT` and accepts the second.
    private final class FlakyResumeProcesses: ProcessPauseBackend, @unchecked Sendable {
        let pid: Int32
        let succeedsOn: Int
        private var resumed = false
        private var resumeAttempts = 0

        init(pid: Int32, succeedsOn: Int) {
            self.pid = pid
            self.succeedsOn = succeedsOn
        }

        func runningProcesses(matching appNames: [String]) -> ProcessScan? {
            ProcessScan(targets: [])
        }
        func identity(ofPid pid: Int32) -> LidCloseActionJournal.ProcessIdentity? {
            guard pid == self.pid else { return nil }
            return .init(pid: pid, startSeconds: 1_700_000_000,
                         startMicroseconds: 0, bootID: "A")
        }
        func stop(pid: Int32) -> Bool { false }
        func resume(pid: Int32) -> Bool {
            guard pid == self.pid else { return false }
            resumeAttempts += 1
            // Delivered but ineffective until the chosen attempt.
            if resumeAttempts >= succeedsOn { resumed = true }
            return true
        }
        func isStopped(pid: Int32) -> Bool? {
            guard pid == self.pid else { return nil }
            return !resumed
        }
    }

    /// A PERSISTENTLY incomplete lid-close undo must not keep an overheating Mac
    /// awake forever: the veto is bounded so heat — the safety case — wins
    /// (gate finding, `Failed lid-close recovery indefinitely vetoes thermal
    /// sleep`).
    func testThermalVetoIsBoundedSoHeatEventuallyWins() {
        var rig = makeRig(state: .critical, flag: true, ownedBoot: "A")

        // A journal that can never be resolved: corrupt on disk.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("veto2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("j.json")
        try? Data("{ truncated".utf8).write(to: url)
        var actions = LidCloseActionService(
            journal: LidCloseActionJournal(url: url),
            auditLog: LidCloseActionAuditLog(url: dir.appendingPathComponent("a.jsonl")),
            audio: NoDeviceAudio(), processes: NoProcesses(), bootID: "A")
        actions.stopConfirmDelay = {}
        rig.service.lidCloseActions = actions

        // First attempts are refused (correct, bounded).
        for _ in 0..<ThermalGuardService.maximumLidCloseVetoes {
            XCTAssertEqual(rig.service.step().mutation, .releaseRefused)
        }
        // Then heat WINS: the Mac must be released.
        XCTAssertEqual(rig.service.step().mutation, .released,
                       "a permanently damaged journal kept the hot Mac awake")
    }


}
