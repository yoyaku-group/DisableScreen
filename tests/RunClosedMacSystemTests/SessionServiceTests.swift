import XCTest
@testable import RunClosedCore
@testable import RunClosedMacSystem
@testable import RunClosedPersistence

/// Action-path tests for the timed session (ADR 023). Model: the ADR 022
/// suite — a fake lid backend that moves a shared flag box, temp-dir stores,
/// injected clocks. Nothing here touches `pmset`.
final class SessionServiceTests: XCTestCase {

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

    /// Mutable clock: the tests move it forward explicitly.
    private final class ClockBox: ContinuousClock, @unchecked Sendable {
        var wall: Date
        var continuous: UInt64
        let bootID: String
        init(wall: Date, continuous seconds: Double, bootID: String = "A") {
            self.wall = wall
            self.continuous = ContinuousClockTimebase.nanoseconds(fromSeconds: seconds)
            self.bootID = bootID
        }
        var nowContinuousNanoseconds: UInt64 { continuous }
        func advance(_ seconds: TimeInterval) {
            wall = wall.addingTimeInterval(seconds)
            continuous += ContinuousClockTimebase.nanoseconds(fromSeconds: seconds)
        }
        /// Wall and continuous advance, but only the continuous counter
        /// represents time that passed while asleep — physically identical,
        /// called out here so the intent of each test reads correctly.
        func sleep(for seconds: TimeInterval) { advance(seconds) }
    }

    private struct Rig {
        var service: SessionService
        let lid: FakeLid
        let flag: FlagBox
        let clock: ClockBox
        let sessionStore: SessionStore
        let latchStore: LowBatteryLatchStore
        let lidStore: OwnedLidAssertion
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    /// - `flag`: observed `disablesleep`.
    /// - `ownedBoot`: nil = no record; "A" = owned on this boot; "OLD" = stale.
    private func makeRig(flag: Bool?, ownedBoot: String?, continuous: Double = 1_000,
                         bootID: String = "A", unwritableSessionStore: Bool = false) -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lidStore = OwnedLidAssertion(currentBootID: bootID,
                                         url: dir.appendingPathComponent("owned_lid.json"))
        if let b = ownedBoot {
            lidStore.save(.init(bootID: b, ownedEnabled: true, referenceState: "on"))
        }
        var sessionURL = dir.appendingPathComponent("session.json")
        if unwritableSessionStore {
            // The parent "directory" is a regular file: no write can succeed.
            let blocker = dir.appendingPathComponent("not-a-dir")
            FileManager.default.createFile(atPath: blocker.path, contents: Data())
            sessionURL = blocker.appendingPathComponent("session.json")
        }
        let sessionStore = SessionStore(url: sessionURL)
        let latchStore = LowBatteryLatchStore(url: dir.appendingPathComponent("latch.json"))
        let flagBox = FlagBox(flag)
        let lid = FakeLid(flag: flagBox)
        let clock = ClockBox(wall: epoch, continuous: continuous, bootID: bootID)

        let service = SessionService(
            store: sessionStore,
            latchStore: latchStore,
            continuous: clock,
            wallClock: { clock.wall },
            observedFlag: { flagBox.value },
            ownershipRecord: {
                let rec = lidStore.load()
                return (rec.bootID, rec.ownedEnabled)
            },
            // Mirrors LidMutationService's gate, including the initiator rules,
            // so a passing test proves the INITIATOR this service sends is one
            // the real service would accept.
            applyLid: { enabled, initiator in
                let rec = lidStore.load()
                if !enabled, initiator != .operatorCommand,
                   !LidMutationService.mayRelease(initiator: initiator,
                                                  record: rec,
                                                  currentBootID: bootID) {
                    return .failure(.notOwned)
                }
                let prior = flagBox.value
                guard LidMutationPolicy.canSet(enabled: enabled, observedPrior: prior) else {
                    if prior == nil { return .failure(.preconditionUnknown) }
                    return .failure(.noChangeRequested(target: enabled))
                }
                let result = lid.setEnabled(enabled)
                if result.state == .verified {
                    var next = lidStore.load()
                    next.bootID = bootID
                    next.ownedEnabled = enabled
                    next.referenceState = enabled ? "on" : "off"
                    lidStore.save(next)
                }
                if result.state == .failed {
                    return .failure(.backendFailed(message: result.error ?? "unknown"))
                }
                return .success(result)
            })
        return Rig(service: service, lid: lid, flag: flagBox, clock: clock,
                   sessionStore: sessionStore, latchStore: latchStore, lidStore: lidStore)
    }

    // MARK: — Start

    func testStartWritesTheJournalBeforeTheFlag() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        guard case .success(.started(let session)) = rig.service.start(for: 3600) else {
            return XCTFail("expected a started session")
        }
        XCTAssertEqual(rig.lid.calls, [true], "one write, through the gated path")
        XCTAssertEqual(rig.flag.value, true)
        XCTAssertEqual(rig.sessionStore.load(), session)
        XCTAssertFalse(session.isIndefinite)
        XCTAssertEqual(rig.lidStore.load().bootID, "A", "ownership claimed on this boot")
        XCTAssertEqual(rig.lidStore.load().ownedEnabled, true)
        XCTAssertEqual(SessionPolicy.remaining(session, now: rig.service.currentNow()) ?? 0,
                       3600, accuracy: 1)
    }

    func testStartIndefiniteBacksThePlainSwitch() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        guard case .success(.started(let session)) = rig.service.start(for: nil) else {
            return XCTFail("expected a started session")
        }
        XCTAssertTrue(session.isIndefinite)
        XCTAssertNil(SessionPolicy.remaining(session, now: rig.service.currentNow()))
    }

    func testStartDeletesTheRecordWhenTheWriteFails() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        rig.lid.failWrites = true
        guard case .failure(let error) = rig.service.start(for: 3600) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error, .backendFailed("sudo: a password is required"))
        XCTAssertNil(rig.sessionStore.load(), "a session not backing a flag must not exist")
    }

    func testStartRefusesWhenTheFlagIsOnButNotOwned() {
        for owned in [nil, "OLD"] as [String?] {
            var rig = makeRig(flag: true, ownedBoot: owned)
            XCTAssertEqual(rig.service.start(for: 3600), .failure(.flagOnNotOwned),
                           "ownedBoot=\(owned as Any)")
            XCTAssertTrue(rig.lid.calls.isEmpty, "no mutation on a refusal")
            XCTAssertNil(rig.sessionStore.load(), "no journal on a refusal")
        }
    }

    func testStartRefusesWhileASessionRuns() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 3600)
        XCTAssertEqual(rig.service.start(for: 7200), .failure(.alreadyRunning))
        XCTAssertEqual(rig.lid.calls, [true], "still one write")
    }

    func testStartAdoptsAnAlreadyOnOwnedFlag() {
        var rig = makeRig(flag: true, ownedBoot: "A")
        guard case .success(.adoptedRunningFlag(let session)) = rig.service.start(for: 7200) else {
            return XCTFail("expected adoption")
        }
        XCTAssertTrue(rig.lid.calls.isEmpty, "the flag was already on: no second pmset write")
        XCTAssertEqual(rig.sessionStore.load(), session)
    }

    // MARK: — Expiry

    func testExpiryReleasesAndClears() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 600)
        XCTAssertEqual(rig.service.expireIfDue(), .notDue, "not due yet")

        rig.clock.advance(601)
        XCTAssertEqual(rig.service.expireIfDue(), .ended(.released))
        XCTAssertEqual(rig.lid.calls, [true, false])
        XCTAssertEqual(rig.flag.value, false)
        XCTAssertNil(rig.sessionStore.load(), "the record is cleared once the release is verified")
        XCTAssertFalse(rig.lidStore.load().ownedEnabled)
    }

    func testExpiryOnTheContinuousClockAfterASleep() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 1800)
        rig.clock.sleep(for: 5400)
        XCTAssertEqual(rig.service.expireIfDue(), .ended(.released))
        XCTAssertNil(rig.sessionStore.load())
    }

    func testExpiryWhenNotOwnedClearsWithoutMutating() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 60)
        // Someone else turned the flag off between the start and the expiry.
        rig.flag.value = false
        rig.lidStore.save(.init(bootID: "A", ownedEnabled: false, referenceState: "off"))
        rig.clock.advance(61)
        XCTAssertEqual(rig.service.expireIfDue(), .ended(.flagNotOwned))
        XCTAssertEqual(rig.lid.calls, [true], "no second write — the flag is already off")
        XCTAssertNil(rig.sessionStore.load())
    }

    func testExpiryRetainsTheRecordWhenTheReleaseFails() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 60)
        rig.lid.failWrites = true
        rig.clock.advance(61)
        guard case .retained(let message) = rig.service.expireIfDue() else {
            return XCTFail("a failed release must retain the record for the next tick")
        }
        XCTAssertTrue(message.contains("password"), message)
        XCTAssertNotNil(rig.sessionStore.load())
    }

    func testExpiryWithNoSessionIsANoOp() {
        var rig = makeRig(flag: true, ownedBoot: "A")
        XCTAssertEqual(rig.service.expireIfDue(), .noSession)
        XCTAssertTrue(rig.lid.calls.isEmpty)
    }

    func testIndefiniteSessionNeverExpires() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: nil)
        rig.clock.advance(30 * 24 * 3600)
        XCTAssertEqual(rig.service.expireIfDue(), .notDue)
        XCTAssertEqual(rig.lid.calls, [true])
    }

    // MARK: — End

    func testEndReleasesAndClears() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 8 * 3600)
        guard case .success(.released) = rig.service.end() else {
            return XCTFail("expected a release")
        }
        XCTAssertNil(rig.sessionStore.load())
        XCTAssertEqual(rig.flag.value, false)
    }

    func testEndWithoutASessionIsRefused() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        XCTAssertEqual(rig.service.end(), .failure(.noSession))
        XCTAssertTrue(rig.lid.calls.isEmpty)
    }

    func testSessionEndCancelsAPendingRearm() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 3600)
        rig.latchStore.save(.init(latch: .init(releasedByGuard: true)))
        _ = rig.service.end()
        XCTAssertFalse(rig.latchStore.load().latch.releasedByGuard)
    }

    func testExpiryCancelsAPendingRearm() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 60)
        rig.latchStore.save(.init(latch: .init(releasedByGuard: true)))
        rig.clock.advance(120)
        XCTAssertEqual(rig.service.expireIfDue(), .ended(.released))
        XCTAssertFalse(rig.latchStore.load().latch.releasedByGuard)
    }

    // MARK: — Extend

    func testExtendMovesTheDeadlineAndKeepsTheIdentity() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        guard case .success(.started(let started)) = rig.service.start(for: 3600) else {
            return XCTFail("expected a started session")
        }
        guard case .success(let extended) = rig.service.extend() else {
            return XCTFail("expected an extension")
        }
        XCTAssertEqual(extended.id, started.id)
        XCTAssertEqual(SessionPolicy.remaining(extended, now: rig.service.currentNow()) ?? 0,
                       1800, accuracy: 1, "+30 min from now")
        XCTAssertEqual(rig.sessionStore.load(), extended)
        XCTAssertEqual(rig.lid.calls, [true], "extending never touches the flag")
    }

    func testExtendWithoutASessionIsRefused() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        XCTAssertEqual(rig.service.extend(), .failure(.noSession))
    }

    func testExtendAnIndefiniteSessionIsRefused() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: nil)
        XCTAssertEqual(rig.service.extend(), .failure(.indefiniteSession))
    }

    // MARK: — Low-battery interplay (ADR 023 §4)

    func testBatteryReleasePausesTheSession() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 2 * 3600)
        XCTAssertTrue(rig.service.pauseForBattery())
        let paused = rig.sessionStore.load()
        XCTAssertEqual(paused?.pausedReason, .lowBattery)
        XCTAssertNotNil(paused?.endsAtWall, "a pause never ends the session")
        XCTAssertFalse(rig.service.pauseForBattery(), "already paused → no second write")
    }

    func testRearmResumesTheSession() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 2 * 3600)
        _ = rig.service.pauseForBattery()
        XCTAssertTrue(rig.service.allowsRearm())
        XCTAssertTrue(rig.service.resumeAfterRearm())
        XCTAssertNil(rig.sessionStore.load()?.pausedReason)
        XCTAssertFalse(rig.service.resumeAfterRearm(), "not paused → nothing to resume")
    }

    func testRearmIsWithheldOnceTheSessionIsDue() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 60)
        rig.clock.advance(120)
        XCTAssertFalse(rig.service.allowsRearm())
    }

    func testRearmIsAllowedWithNoSessionAtAll() {
        // ADR 022 behaviour without a session must not change.
        let rig = makeRig(flag: false, ownedBoot: nil)
        XCTAssertTrue(rig.service.allowsRearm())
    }

    // MARK: — Quit teardown and the duration cap (review round 1)

    /// Regression: a session paused by the battery guard, then the app quits.
    /// The quit teardown must clear the guard's pending re-arm too, or the
    /// next launch on AC would flip the flag back ON for a session that no
    /// longer exists (ADR 023 §4).
    func testQuitTeardownClearsAPendingRearmOfAPausedSession() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 2 * 3600)
        XCTAssertTrue(rig.service.pauseForBattery())
        rig.flag.value = false
        rig.latchStore.save(.init(latch: .init(releasedByGuard: true)))

        rig.service.finishOnQuit(flagReadsOff: true)

        XCTAssertNil(rig.sessionStore.load())
        let latch = rig.latchStore.load().latch
        XCTAssertFalse(latch.releasedByGuard)
        // Next launch, on AC well above the re-arm threshold: no re-arm.
        let step = LowBatteryPolicy.step(
            .init(onBattery: false, chargePercent: 80, minutesRemaining: nil,
                  lidFlag: false, ownership: .notOwned, acDraining: false),
            latch: latch)
        XCTAssertNotEqual(step.decision.action, .rearm)
    }

    /// ADR 022 unchanged: with no session on disk the quit path leaves the
    /// plain switch's pending re-arm alone.
    func testQuitWithoutASessionLeavesAPendingRearm() {
        let rig = makeRig(flag: false, ownedBoot: nil)
        rig.latchStore.save(.init(latch: .init(releasedByGuard: true)))
        rig.service.finishOnQuit(flagReadsOff: true)
        XCTAssertTrue(rig.latchStore.load().latch.releasedByGuard)
    }

    /// The flag still reads ON after the restore (not ours, or the restore
    /// failed): the record is kept, a later tick or the backstop retries.
    func testQuitKeepsTheSessionWhileTheFlagStillReadsOn() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 3600)
        rig.service.finishOnQuit(flagReadsOff: false)
        XCTAssertNotNil(rig.sessionStore.load())
    }

    func testStartPastTheCapIsRefusedBeforeAnyWrite() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        let result = rig.service.start(for: SessionDuration.maximum + 1)
        XCTAssertEqual(result.failureValue, .durationTooLong)
        XCTAssertNil(rig.sessionStore.load(), "nothing journaled")
        XCTAssertEqual(rig.flag.value, false, "flag untouched")
    }

    func testExtendPastTheCapIsRefused() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 3600)
        let before = rig.sessionStore.load()
        let result = rig.service.extend(by: SessionDuration.maximum + 1)
        XCTAssertEqual(result.failureValue, .durationTooLong)
        XCTAssertEqual(rig.sessionStore.load(), before)
    }
    // MARK: — Review round 2

    /// Journal before change: when session.json cannot be written, the flag
    /// is never touched.
    func testStartNeverSetsTheFlagWhenTheJournalCannotBeWritten() {
        var rig = makeRig(flag: false, ownedBoot: nil, unwritableSessionStore: true)
        let result = rig.service.start(for: 3600)
        XCTAssertEqual(result.failureValue, .backendFailed("session record could not be written"))
        XCTAssertEqual(rig.lid.calls, [], "no pmset write without a journal")
        XCTAssertEqual(rig.flag.value, false)
    }

    /// A failed start puts back the due session it replaced: the next tick
    /// still has to end that deadline through the ownership gate.
    func testFailedStartRestoresTheDueSessionItReplaced() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 60)
        let due = rig.sessionStore.load()
        rig.clock.advance(120)
        rig.flag.value = false            // the flag went OFF; the due record is still on disk
        rig.lid.failWrites = true
        guard case .failure = rig.service.start(for: 3600) else { return XCTFail("expected a failure") }
        XCTAssertEqual(rig.lid.calls.last, true, "the start did try to set the flag")
        XCTAssertEqual(rig.sessionStore.load(), due)
    }

    /// Extend moves the deadline but never resumes a battery pause: the flag
    /// is still OFF until the guard re-arms it.
    func testExtendKeepsABatteryPause() {
        var rig = makeRig(flag: false, ownedBoot: nil)
        _ = rig.service.start(for: 3600)
        _ = rig.service.pauseForBattery()
        guard case .success(let next) = rig.service.extend(by: 1800) else { return XCTFail("expected success") }
        XCTAssertEqual(next.pausedReason, .lowBattery)
        XCTAssertEqual(rig.sessionStore.load()?.pausedReason, .lowBattery)
    }

    /// The plain switch (indefinite session) keeps ADR 022's re-arm on any
    /// boot; only a timed session is bound to its boot.
    func testIndefiniteSessionFromAnotherBootStillAllowsTheRearm() {
        let rig = makeRig(flag: false, ownedBoot: nil, bootID: "B")
        rig.sessionStore.save(KeepAwakeSession(startedAt: epoch, bootID: "A"))
        XCTAssertTrue(rig.service.allowsRearm())
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
