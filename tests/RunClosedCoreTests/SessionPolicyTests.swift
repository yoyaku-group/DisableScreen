import XCTest
@testable import RunClosedCore

/// Pure session policy tests (ADR 023). No I/O, no clock, no `pmset` — every
/// case below is a fact about the rules, not about the machine.
final class SessionPolicyTests: XCTestCase {

    private enum Boot {
        static let a = "boot-A"
        static let b = "boot-B"
    }
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func now(
        wallOffset: TimeInterval = 0,
        continuousSeconds: Double = 1_000,
        bootID: String = Boot.a
    ) -> SessionPolicy.Now {
        SessionPolicy.Now(
            wall: Self.epoch.addingTimeInterval(wallOffset),
            continuousNanoseconds: ContinuousClockTimebase.nanoseconds(fromSeconds: continuousSeconds),
            bootID: bootID)
    }

    private func timed(
        _ duration: TimeInterval,
        startedAt offset: TimeInterval = 0,
        continuousStart: Double = 1_000,
        bootID: String = Boot.a
    ) -> KeepAwakeSession {
        KeepAwakeSession(
            startedAt: Self.epoch.addingTimeInterval(offset),
            endsAtWall: Self.epoch.addingTimeInterval(offset).addingTimeInterval(duration),
            endsAtContinuous: ContinuousClockTimebase.nanoseconds(fromSeconds: continuousStart + duration),
            bootID: bootID)
    }

    // MARK: — Due on the continuous clock (same boot)

    func testDueOnContinuousClockOnSameBoot() {
        let session = timed(3600)
        XCTAssertFalse(SessionPolicy.isDue(session, now: now(continuousSeconds: 2_000)))
        XCTAssertTrue(SessionPolicy.isDue(session, now: now(wallOffset: 3600, continuousSeconds: 4_600)))
        XCTAssertEqual(SessionPolicy.dueReason(session, now: now(continuousSeconds: 4_600)),
                       .continuousDeadline)
    }

    func testNotDueBeforeDeadline() {
        let session = timed(3600)
        XCTAssertNil(SessionPolicy.dueReason(session, now: now(wallOffset: 3599, continuousSeconds: 4_599)))
        XCTAssertEqual(SessionPolicy.remaining(session, now: now(continuousSeconds: 2_200)) ?? -1,
                       2400, accuracy: 0.001)
    }

    /// The whole point of `mach_continuous_time`: a laptop that slept for six
    /// hours inside a one-hour session is due, even though a suspended timer
    /// (and `systemUptime`) would still believe it has an hour left.
    func testDueAfterSleepThatTheUptimeClockWouldMiss() {
        let session = timed(3600)   // deadline at continuous 4600
        // Wall advanced 6 h, continuous advanced 6 h, uptime advanced ~0.
        let afterSleep = now(wallOffset: 6 * 3600, continuousSeconds: 1_000 + 6 * 3600)
        XCTAssertTrue(SessionPolicy.isDue(session, now: afterSleep))
        XCTAssertEqual(SessionPolicy.remaining(session, now: afterSleep), 0)
    }

    // MARK: — Due on the wall clock across boots

    func testDueOnWallClockAcrossBoots() {
        let session = timed(3600, bootID: Boot.a)
        // Different boot: the continuous counter restarted, so it cannot decide.
        let nextBoot = SessionPolicy.Now(wall: Self.epoch.addingTimeInterval(1800),
                                         continuousNanoseconds: 5, bootID: Boot.b)
        XCTAssertFalse(SessionPolicy.isDue(session, now: nextBoot),
                       "a fresh counter must not be compared with a previous boot's deadline")
        let laterOnNextBoot = SessionPolicy.Now(wall: Self.epoch.addingTimeInterval(3601),
                                                continuousNanoseconds: 5, bootID: Boot.b)
        XCTAssertTrue(SessionPolicy.isDue(session, now: laterOnNextBoot))
        XCTAssertEqual(SessionPolicy.dueReason(session, now: laterOnNextBoot), .wallDeadline)
    }

    func testContinuousDeadlineIsIgnoredOnAnotherBoot() {
        // The old boot's continuous deadline is numerically tiny compared with
        // the new boot's counter — a naive comparison would end the session
        // instantly. It must be skipped in favour of the wall deadline.
        let session = timed(8 * 3600, bootID: Boot.a)   // continuous deadline 29800
        let earlyNextBoot = SessionPolicy.Now(wall: Self.epoch.addingTimeInterval(60),
                                              continuousNanoseconds: ContinuousClockTimebase.nanoseconds(fromSeconds: 900_000),
                                              bootID: Boot.b)
        XCTAssertFalse(SessionPolicy.isDue(session, now: earlyNextBoot))
    }

    // MARK: — Indefinite sessions never come due

    func testIndefiniteSessionIsNeverDue() {
        let session = KeepAwakeSession(startedAt: Self.epoch, bootID: Boot.a)
        XCTAssertTrue(session.isIndefinite)
        XCTAssertFalse(SessionPolicy.isDue(session, now: now(wallOffset: 10 * 365 * 24 * 3600,
                                                             continuousSeconds: 1e9)))
        XCTAssertNil(SessionPolicy.remaining(session, now: now(continuousSeconds: 2_000)))
        XCTAssertNil(SessionPolicy.remainingLabel(session, now: now(continuousSeconds: 2_000)))
        XCTAssertNil(SessionPolicy.rowLabel(session, now: now(continuousSeconds: 2_000)))
    }

    // MARK: — Start

    func testStartTimedSetsBothDeadlines() {
        let result = SessionPolicy.start(duration: 2 * 3600, now: now(),
                                         observedFlag: false, ownership: .notOwned)
        guard case .success(let session) = result else { return XCTFail("expected success") }
        XCTAssertFalse(session.isIndefinite)
        XCTAssertEqual(session.bootID, Boot.a)
        XCTAssertEqual(session.endsAtWall, Self.epoch.addingTimeInterval(2 * 3600))
        XCTAssertEqual(ContinuousClockTimebase.seconds(fromNanoseconds: session.endsAtContinuous!),
                       1_000 + 2 * 3600, accuracy: 0.001)
    }

    func testStartIndefiniteHasNoDeadline() {
        let result = SessionPolicy.start(duration: nil, now: now(),
                                         observedFlag: false, ownership: .notOwned)
        guard case .success(let session) = result else { return XCTFail("expected success") }
        XCTAssertTrue(session.isIndefinite)
    }

    /// Expiry would silently fail `notOwned` on a flag we do not own, leaving
    /// an awake machine with no deadline. Refuse up front instead.
    func testRefusesTimedStartWhenFlagOnButNotOwned() {
        for ownership in [LowBatteryPolicy.LidOwnership.notOwned, .staleRecord] {
            let result = SessionPolicy.start(duration: 3600, now: now(),
                                             observedFlag: true, ownership: ownership)
            XCTAssertEqual(result, .failure(.flagOnNotOwned), "ownership=\(ownership)")
        }
    }

    func testAllowsTimedStartWhenFlagOnAndOwned() {
        let result = SessionPolicy.start(duration: 3600, now: now(),
                                         observedFlag: true, ownership: .ownedThisBoot)
        guard case .success = result else { return XCTFail("expected success") }
    }

    /// The plain switch keeps working exactly as before: an indefinite start
    /// is not blocked by the ownership rule (ADR 021 already governs it).
    func testIndefiniteStartIsNotBlockedByOwnership() {
        let result = SessionPolicy.start(duration: nil, now: now(),
                                         observedFlag: true, ownership: .notOwned)
        guard case .success = result else { return XCTFail("expected success") }
    }

    func testRefusesSecondSessionWhileOneRuns() {
        let existing = timed(3600)
        let result = SessionPolicy.start(duration: 7200, now: now(continuousSeconds: 2_000),
                                         observedFlag: true, ownership: .ownedThisBoot,
                                         existing: existing)
        XCTAssertEqual(result, .failure(.alreadyRunning))
    }

    func testReplacesASessionThatIsAlreadyDue() {
        let existing = timed(3600)
        let result = SessionPolicy.start(duration: 7200, now: now(wallOffset: 4000, continuousSeconds: 5_000),
                                         observedFlag: true, ownership: .ownedThisBoot,
                                         existing: existing)
        guard case .success(let session) = result else { return XCTFail("expected success") }
        XCTAssertNotEqual(session.id, existing.id)
    }

    func testRefusesNonPositiveDuration() {
        XCTAssertEqual(SessionPolicy.start(duration: 0, now: now(), observedFlag: false,
                                           ownership: .ownedThisBoot),
                       .failure(.nonPositiveDuration))
        XCTAssertEqual(SessionPolicy.start(duration: -60, now: now(), observedFlag: false,
                                           ownership: .ownedThisBoot),
                       .failure(.nonPositiveDuration))
    }

    // MARK: — Extend

    func testExtendPushesDeadlineFromNow() {
        let session = timed(3600)
        let later = now(wallOffset: 600, continuousSeconds: 1_600)
        let extended = SessionPolicy.extend(session, by: 1800, now: later)
        XCTAssertEqual(extended.endsAtWall, Self.epoch.addingTimeInterval(600 + 1800))
        XCTAssertEqual(ContinuousClockTimebase.seconds(fromNanoseconds: extended.endsAtContinuous!),
                       1_600 + 1800, accuracy: 0.001)
        XCTAssertEqual(extended.id, session.id, "extend keeps the session identity")
    }

    func testExtendRevivesADueSession() {
        let session = timed(600)
        let late = now(wallOffset: 5_000, continuousSeconds: 6_000)
        XCTAssertTrue(SessionPolicy.isDue(session, now: late))
        let extended = SessionPolicy.extend(session, by: 30 * 60, now: late)
        XCTAssertFalse(SessionPolicy.isDue(extended, now: late))
    }

    /// Review round 2: extend only moves the deadline. The flag is still OFF
    /// after a battery release, so the session must stay paused until the
    /// guard re-arms it.
    func testExtendKeepsABatteryPause() {
        let paused = SessionPolicy.pause(timed(3600), reason: .lowBattery)
        XCTAssertEqual(paused.pausedReason, .lowBattery)
        let extended = SessionPolicy.extend(paused, by: 60, now: now(continuousSeconds: 2_000))
        XCTAssertEqual(extended.pausedReason, .lowBattery)
        XCTAssertNotEqual(extended.endsAtWall, paused.endsAtWall, "the deadline still moves")
    }

    func testExtendIsANoOpOnAnIndefiniteSessionAndOnNonPositiveSteps() {
        let indefinite = KeepAwakeSession(startedAt: Self.epoch, bootID: Boot.a)
        XCTAssertEqual(SessionPolicy.extend(indefinite, by: 1800, now: now()), indefinite)
        let timedSession = timed(3600)
        XCTAssertEqual(SessionPolicy.extend(timedSession, by: 0, now: now()), timedSession)
        XCTAssertEqual(SessionPolicy.extend(timedSession, by: -5, now: now()), timedSession)
    }

    // MARK: — Pause / resume

    func testPauseAndResumeKeepTheDeadline() {
        let session = timed(3600)
        let paused = SessionPolicy.pause(session, reason: .lowBattery)
        XCTAssertEqual(paused.pausedReason, .lowBattery)
        XCTAssertEqual(paused.endsAtWall, session.endsAtWall, "a pause never moves the deadline")
        XCTAssertEqual(paused.endsAtContinuous, session.endsAtContinuous)
        XCTAssertEqual(paused.id, session.id)
        XCTAssertNil(SessionPolicy.resume(paused).pausedReason)
    }

    func testAllowsRearmOnlyForALiveSessionOnThisBoot() {
        let session = timed(3600)
        XCTAssertTrue(SessionPolicy.allowsRearm(session, now: now(continuousSeconds: 2_000)))
        // Due: the session is over, the guard must not bring the flag back.
        XCTAssertFalse(SessionPolicy.allowsRearm(session, now: now(wallOffset: 4_000,
                                                                    continuousSeconds: 5_000)))
        // Another boot: the counters do not line up, so no re-arm.
        XCTAssertFalse(SessionPolicy.allowsRearm(session, now: SessionPolicy.Now(
            wall: Self.epoch, continuousNanoseconds: 1, bootID: Boot.b)))
    }

    /// The plain switch is ADR 022's: it re-arms on any boot.
    func testAllowsRearmForTheIndefiniteSwitchOnAnyBoot() {
        let indefinite = KeepAwakeSession(startedAt: Self.epoch, bootID: Boot.a)
        XCTAssertTrue(SessionPolicy.allowsRearm(indefinite, now: SessionPolicy.Now(
            wall: Self.epoch, continuousNanoseconds: 1, bootID: Boot.b)))
    }

    // MARK: — Presentation

    func testRemainingLabelFormats() {
        let session = timed(2 * 3600 + 41 * 60)
        let label = SessionPolicy.remainingLabel(session, now: now(continuousSeconds: 1_000))
        XCTAssertEqual(label, "2 h 41 left")

        let minutesOnly = timed(8 * 60)
        XCTAssertEqual(SessionPolicy.remainingLabel(minutesOnly, now: now(continuousSeconds: 1_000)),
                       "8 min left")

        let exactHour = timed(3600)
        XCTAssertEqual(SessionPolicy.remainingLabel(exactHour, now: now(continuousSeconds: 1_000)),
                       "1 h left")

        let atDeadline = timed(0)
        XCTAssertEqual(SessionPolicy.remainingLabel(atDeadline, now: now(continuousSeconds: 1_000)),
                       "< 1 min left")

        let justUnderAMinute = timed(30)
        XCTAssertEqual(SessionPolicy.remainingLabel(justUnderAMinute, now: now(continuousSeconds: 1_000)),
                       "1 min left", "ceil to the next minute — never a zero-minute label")
    }

    func testRowLabelShowsUntilAndRemaining() {
        let session = timed(2 * 3600 + 41 * 60)
        let label = SessionPolicy.rowLabel(session, now: now(continuousSeconds: 1_000),
                                           timeZone: TimeZone(identifier: "Europe/Paris")!,
                                           locale: Locale(identifier: "en_GB"))
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.hasPrefix("Until "), label!)
        XCTAssertTrue(label!.hasSuffix("· 2 h 41 left"), label!)
    }

    // MARK: — Duration parsing

    func testDurationParsing() {
        XCTAssertEqual(SessionDuration.parse("2h"), 7200)
        XCTAssertEqual(SessionDuration.parse("90m"), 5400)
        XCTAssertEqual(SessionDuration.parse("1h30m"), 5400)
        XCTAssertEqual(SessionDuration.parse("1h30"), 5400, "a trailing bare number inherits the smaller unit")
        XCTAssertEqual(SessionDuration.parse("45"), 45 * 60, "bare numbers are minutes")
        XCTAssertEqual(SessionDuration.parse("30s"), 30)
        XCTAssertEqual(SessionDuration.parse("2H"), 7200, "case-insensitive")
        XCTAssertNil(SessionDuration.parse(""))
        XCTAssertNil(SessionDuration.parse("abc"))
        XCTAssertNil(SessionDuration.parse("2x"))
        XCTAssertNil(SessionDuration.parse("h"))
        XCTAssertNil(SessionDuration.parse("0"))
        XCTAssertNil(SessionDuration.parse("-5m"))
    }

    func testPresetsAndExtendStep() {
        XCTAssertEqual(SessionDuration.presets, [3600, 7200, 14_400, 28_800] as [TimeInterval])
        XCTAssertEqual(SessionDuration.extendStep, 1800)
    }

    // MARK: — Continuous clock plumbing

    func testContinuousClockAdvancesMonotonically() {
        let clock = SystemContinuousClock(bootID: "b")
        let first = clock.nowContinuousNanoseconds
        let second = clock.nowContinuousNanoseconds
        XCTAssertGreaterThanOrEqual(second, first)
        XCTAssertGreaterThan(first, 0, "mach_continuous_time is never zero on a booted machine")
    }

    func testNanosecondRoundTrip() {
        let ns = ContinuousClockTimebase.nanoseconds(fromSeconds: 3600)
        XCTAssertEqual(ContinuousClockTimebase.seconds(fromNanoseconds: ns), 3600, accuracy: 0.001)
        XCTAssertEqual(ContinuousClockTimebase.nanoseconds(fromSeconds: -1), 0)
    }

    // MARK: — Duration cap and trap-free conversion (review round 1)

    func testStartAtTheCapIsAcceptedAndPastItRefused() {
        let atCap = SessionPolicy.start(duration: SessionDuration.maximum, now: now(),
                                        observedFlag: false, ownership: .notOwned)
        guard case .success = atCap else { return XCTFail("7 days is allowed") }
        let past = SessionPolicy.start(duration: SessionDuration.maximum + 1, now: now(),
                                       observedFlag: false, ownership: .notOwned)
        guard case .failure(.durationTooLong) = past else { return XCTFail("expected durationTooLong") }
    }

    func testNonFiniteDurationsAreRefused() {
        for bad in [Double.infinity, -Double.infinity, Double.nan] {
            let r = SessionPolicy.start(duration: bad, now: now(),
                                        observedFlag: false, ownership: .notOwned)
            guard case .failure(.nonPositiveDuration) = r else {
                return XCTFail("\(bad) must be refused")
            }
        }
    }

    func testExtendPastTheCapLeavesTheSessionUnchanged() {
        let session = timed(3600)
        XCTAssertEqual(SessionPolicy.extend(session, by: SessionDuration.maximum + 1, now: now()), session)
        XCTAssertEqual(SessionPolicy.extend(session, by: .infinity, now: now()), session)
        XCTAssertEqual(SessionPolicy.extend(session, by: .nan, now: now()), session)
    }

    func testHugeOrNonNumericDurationTextIsNotAcceptable() {
        // Parses (a number with a unit) but is far past the cap: the CLI
        // turns this into exit 64 before any lock or write.
        if let huge = SessionDuration.parse("999999999999h") {
            XCTAssertFalse(SessionDuration.isAcceptable(huge))
        }
        XCTAssertNil(SessionDuration.parse("inf"))
        XCTAssertNil(SessionDuration.parse("nan"))
        XCTAssertTrue(SessionDuration.isAcceptable(2 * 3600))
        XCTAssertFalse(SessionDuration.isAcceptable(0))
    }

    func testNanosecondConversionNeverTraps() {
        XCTAssertEqual(ContinuousClockTimebase.nanoseconds(fromSeconds: .infinity), 0)
        XCTAssertEqual(ContinuousClockTimebase.nanoseconds(fromSeconds: .nan), 0)
        XCTAssertEqual(ContinuousClockTimebase.nanoseconds(fromSeconds: -5), 0)
        XCTAssertEqual(ContinuousClockTimebase.nanoseconds(fromSeconds: 1e30), UInt64.max)
        XCTAssertEqual(ContinuousClockTimebase.nanoseconds(fromSeconds: 1.5), 1_500_000_000)
    }

    func testContinuousDeadlineSaturatesInsteadOfWrapping() {
        let nearTop = UInt64.max - 5
        XCTAssertEqual(SessionPolicy.addingContinuous(nearTop, seconds: 3600), UInt64.max)
        XCTAssertEqual(SessionPolicy.addingContinuous(1_000, seconds: 1), 1_000 + 1_000_000_000)
    }

    // MARK: — Review round 3

    /// Switching ON over a battery-paused timed session resumes it with its
    /// deadline instead of replacing it with an indefinite one.
    func testSwitchOnResumesAPausedTimedSession() {
        let paused = SessionPolicy.pause(timed(7200), reason: .lowBattery)
        let next = SessionPolicy.recordAfterSwitchOn(existing: paused, now: now(wallOffset: 600, continuousSeconds: 1_600))
        XCTAssertEqual(next.id, paused.id)
        XCTAssertEqual(next.endsAtWall, paused.endsAtWall)
        XCTAssertEqual(next.endsAtContinuous, paused.endsAtContinuous)
        XCTAssertNil(next.pausedReason)
    }

    func testSwitchOnKeepsARunningTimedSession() {
        let running = timed(7200)
        XCTAssertEqual(SessionPolicy.recordAfterSwitchOn(existing: running, now: now()), running)
    }

    func testSwitchOnReplacesADueOrForeignOrMissingSessionWithAnIndefiniteOne() {
        let due = SessionPolicy.pause(timed(60), reason: .lowBattery)
        let foreign = SessionPolicy.pause(timed(7200, bootID: Boot.b), reason: .lowBattery)
        let current = now(wallOffset: 120, continuousSeconds: 1_120)
        for existing in [due, foreign, nil, KeepAwakeSession(startedAt: Self.epoch, bootID: Boot.a)] {
            let next = SessionPolicy.recordAfterSwitchOn(existing: existing, now: current)
            XCTAssertTrue(next.isIndefinite)
            XCTAssertFalse(next.isPaused)
            XCTAssertEqual(next.bootID, Boot.a)
            XCTAssertEqual(next.startedAt, current.wall)
            if let existing { XCTAssertNotEqual(next.id, existing.id) }
        }
    }

    func testStartArgumentsParse() {
        XCTAssertEqual(SessionDuration.parseStartArguments(["--for", "2h"]), .success(.timed(7200)))
        XCTAssertEqual(SessionDuration.parseStartArguments(["--indefinite"]), .success(.indefinite))
    }

    /// `--for` with `--indefinite` is refused: neither reading is safe to guess.
    func testStartArgumentsRefuseBothModes() {
        XCTAssertEqual(SessionDuration.parseStartArguments(["--for", "2h", "--indefinite"]), .failure(.usage))
        XCTAssertEqual(SessionDuration.parseStartArguments(["--indefinite", "--for", "2h"]), .failure(.usage))
    }

    func testStartArgumentsRefuseUsageErrorsAndTheCap() {
        XCTAssertEqual(SessionDuration.parseStartArguments([]), .failure(.usage))
        XCTAssertEqual(SessionDuration.parseStartArguments(["--for"]), .failure(.usage))
        XCTAssertEqual(SessionDuration.parseStartArguments(["--for", "soon"]), .failure(.usage))
        XCTAssertEqual(SessionDuration.parseStartArguments(["--bogus"]), .failure(.usage))
        XCTAssertEqual(SessionDuration.parseStartArguments(["--for", "200h"]), .failure(.overCap))
    }

    // MARK: — Review round 5

    /// A session from a previous boot extended on this one gets a wall
    /// deadline only: this boot's counter filed under the old bootID would
    /// mean nothing, and the bootID must stay for `.sessionRecovery`.
    func testExtendOnAnotherBootKeepsTheBootAndDropsTheContinuousDeadline() {
        let session = timed(3600, bootID: Boot.a)
        let extended = SessionPolicy.extend(session, by: 1800,
                                            now: now(continuousSeconds: 50, bootID: Boot.b))
        XCTAssertEqual(extended.bootID, Boot.a)
        XCTAssertNil(extended.endsAtContinuous)
        XCTAssertEqual(extended.endsAtWall, Self.epoch.addingTimeInterval(1800))
        XCTAssertFalse(extended.isIndefinite)
    }

    func testExtendOnTheSameBootKeepsTheContinuousDeadline() {
        let extended = SessionPolicy.extend(timed(3600), by: 1800, now: now(continuousSeconds: 2_000))
        XCTAssertEqual(extended.endsAtContinuous,
                       ContinuousClockTimebase.nanoseconds(fromSeconds: 3_800))
    }

    /// The menu-bar title: digits and unit letters only, so it reads the
    /// same in every language.
    func testCompactRemainingLabel() {
        let session = timed(3 * 3600)
        XCTAssertEqual(SessionPolicy.compactRemainingLabel(session, now: now(continuousSeconds: 1_000)), "3h")
        XCTAssertEqual(SessionPolicy.compactRemainingLabel(
            session, now: now(wallOffset: 3600 + 19 * 60, continuousSeconds: 1_000 + 3600 + 19 * 60)), "1h41")
        XCTAssertEqual(SessionPolicy.compactRemainingLabel(
            session, now: now(wallOffset: 3600 + 55 * 60, continuousSeconds: 1_000 + 3600 + 55 * 60)), "1h05")
        XCTAssertEqual(SessionPolicy.compactRemainingLabel(
            session, now: now(wallOffset: 2 * 3600 + 15 * 60, continuousSeconds: 1_000 + 2 * 3600 + 15 * 60)), "45m")
        XCTAssertEqual(SessionPolicy.compactRemainingLabel(
            session, now: now(wallOffset: 3 * 3600, continuousSeconds: 1_000 + 3 * 3600)), "<1m")
        XCTAssertNil(SessionPolicy.compactRemainingLabel(
            KeepAwakeSession(startedAt: Self.epoch, bootID: Boot.a), now: now()))
    }
}
