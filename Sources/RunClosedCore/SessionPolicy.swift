import Foundation

/// Pure session policy (ADR 023). No I/O, no AppKit, no subprocess — the same
/// stance as `LidMutationPolicy` and `LowBatteryPolicy`, so the rules below are
/// testable without a Mac (and without touching the real power flag).
///
/// Three questions, three answers:
///   1. MAY a timed session start now? (`start`)
///   2. IS the running session due?      (`isDue`)
///   3. WHAT does the operator see?      (`remaining`, `label`)
public enum SessionPolicy {

    /// The instant to evaluate against. Both clocks are injected because a
    /// deadline is only honest when read from the clock that suits it:
    /// the continuous counter for "did the sleep we asked for elapse", the
    /// wall clock for "did we cross a reboot".
    public struct Now: Equatable, Sendable {
        public var wall: Date
        public var continuousNanoseconds: UInt64
        public var bootID: String

        public init(wall: Date, continuousNanoseconds: UInt64, bootID: String) {
            self.wall = wall
            self.continuousNanoseconds = continuousNanoseconds
            self.bootID = bootID
        }
    }

    /// Why a start was refused. Each maps to a distinct CLI exit path/string —
    /// a caller must never have to guess which rule fired.
    public enum StartRefusal: Error, Equatable, Sendable {
        /// The flag reads ON but RunClosed does not own it on this boot (no
        /// record, or a record from a previous boot). Starting a timed session
        /// here would look successful and then fail `notOwned` at expiry,
        /// leaving the machine awake with no deadline — the exact silent
        /// failure ADR 023 exists to remove. Refuse up front instead.
        case flagOnNotOwned
        /// A session is already running. Extend or end it; never stack.
        case alreadyRunning
        /// A duration of zero (or less) is not a session.
        case nonPositiveDuration
        /// Beyond `SessionDuration.maximum` (7 days) — a usage error, not a
        /// session we are willing to journal.
        case durationTooLong
    }

    /// Saturating add: a deadline past the counter's range clamps instead of
    /// wrapping to a value in the past (which would make the session
    /// instantly due) or trapping.
    static func addingContinuous(_ base: UInt64, seconds: TimeInterval) -> UInt64 {
        let delta = ContinuousClockTimebase.nanoseconds(
            fromSeconds: SessionDuration.clamped(seconds))
        let (sum, overflowed) = base.addingReportingOverflow(delta)
        return overflowed ? UInt64.max : sum
    }

    /// Why a session came due.
    public enum DueReason: String, Codable, Sendable, Equatable {
        /// The continuous counter (`mach_continuous_time`) passed the deadline
        /// on the boot that set it. Survives sleep, so this is the normal case.
        case continuousDeadline
        /// The wall clock passed the deadline. This is the only signal that
        /// still works after a reboot (the counter restarted) or a wall-clock
        /// jump forward.
        case wallDeadline
    }

    // MARK: — Due

    /// Which deadline, if any, has elapsed. `nil` = not due.
    ///
    /// An indefinite session (`endsAt == nil`) is NEVER due — that is what
    /// keeps the plain switch a plain switch.
    ///
    /// The continuous deadline is only honoured on the boot that wrote it: the
    /// counter restarts at boot, so comparing a previous boot's value against
    /// today's counter would be meaningless (and could be either direction).
    public static func dueReason(_ session: KeepAwakeSession, now: Now) -> DueReason? {
        if session.isOnBoot(now.bootID),
           let deadline = session.endsAtContinuous,
           now.continuousNanoseconds >= deadline {
            return .continuousDeadline
        }
        if let deadline = session.endsAtWall, now.wall >= deadline {
            return .wallDeadline
        }
        return nil
    }

    public static func isDue(_ session: KeepAwakeSession, now: Now) -> Bool {
        dueReason(session, now: now) != nil
    }

    // MARK: — Time left

    /// Time left before the session is due; `nil` for an indefinite session.
    /// A due session reports 0 rather than a negative number.
    ///
    /// The two clocks disagree by design (a slept hour shows up in the
    /// continuous clock, not in a suspended timer), so the answer is the
    /// EARLIEST deadline that still applies — the one that will fire first.
    public static func remaining(_ session: KeepAwakeSession, now: Now) -> TimeInterval? {
        var candidates: [TimeInterval] = []
        if session.isOnBoot(now.bootID), let deadline = session.endsAtContinuous {
            let nowNS = now.continuousNanoseconds
            candidates.append(deadline > nowNS
                ? ContinuousClockTimebase.seconds(fromNanoseconds: deadline - nowNS)
                : 0)
        }
        if let deadline = session.endsAtWall {
            candidates.append(max(0, deadline.timeIntervalSince(now.wall)))
        }
        return candidates.min()
    }

    // MARK: — Start

    /// Start a session of `duration` seconds, or an indefinite one when
    /// `duration == nil`.
    ///
    /// `observedFlag`/`ownership` are the live `pmset -g` reading and the
    /// classification of `owned_lid.json` against this boot. The ownership
    /// refusal is scoped to TIMED sessions: an indefinite session is today's
    /// plain switch, whose operator path already exists (ADR 021) and must not
    /// change behaviour here.
    public static func start(
        duration: TimeInterval?,
        now: Now,
        observedFlag: Bool?,
        ownership: LowBatteryPolicy.LidOwnership,
        existing: KeepAwakeSession? = nil
    ) -> Result<KeepAwakeSession, StartRefusal> {
        if let existing, !isDue(existing, now: now) {
            return .failure(.alreadyRunning)
        }
        if let duration {
            guard duration.isFinite, duration > 0 else { return .failure(.nonPositiveDuration) }
            // Above the cap is a usage error, not a session: an overflowed or
            // effectively-infinite deadline is not something to journal.
            guard duration <= SessionDuration.maximum else { return .failure(.durationTooLong) }
        }
        if duration != nil, observedFlag == true, ownership != .ownedThisBoot {
            return .failure(.flagOnNotOwned)
        }
        var session = KeepAwakeSession(startedAt: now.wall, bootID: now.bootID)
        if let duration {
            session.endsAtContinuous = addingContinuous(
                now.continuousNanoseconds, seconds: duration)
            session.endsAtWall = now.wall.addingTimeInterval(duration)
        }
        return .success(session)
    }

    // MARK: — Extend / end / pause

    /// Push the deadline out by `seconds` from NOW (not from the old
    /// deadline): "+30 min" means half an hour more, even on a session that
    /// already lapsed. An indefinite session stays indefinite — extending it
    /// would silently invent a deadline the operator never asked for.
    public static func extend(
        _ session: KeepAwakeSession,
        by seconds: TimeInterval,
        now: Now
    ) -> KeepAwakeSession {
        guard !session.isIndefinite, seconds.isFinite, seconds > 0,
              seconds <= SessionDuration.maximum else { return session }
        var next = session
        // The continuous deadline only means something on the boot that wrote
        // the session (`dueReason` ignores it elsewhere). Extending a session
        // from a previous boot keeps its bootID, which `.sessionRecovery`
        // matches against the ownership record, so it gets a wall deadline
        // only — never this boot's counter filed under another boot.
        next.endsAtContinuous = session.isOnBoot(now.bootID)
            ? addingContinuous(now.continuousNanoseconds, seconds: seconds)
            : nil
        next.endsAtWall = now.wall.addingTimeInterval(seconds)
        // A battery pause survives an extension: the guard released the flag
        // and only its re-arm (on AC, above the threshold) turns it back on.
        // Clearing the pause here would show a running countdown while
        // `disablesleep` reads 0 and the Mac sleeps on lid close.
        return next
    }

    /// The low-battery guard released the flag: the session is PAUSED, not
    /// ended (ADR 023 §4). The deadline is untouched — the operator asked for
    /// "until 14:30", not "until the battery got low".
    public static func pause(_ session: KeepAwakeSession, reason: SessionPauseReason) -> KeepAwakeSession {
        var next = session
        next.pausedReason = reason
        return next
    }

    /// The guard re-armed the flag and the session is still valid: resume it.
    public static func resume(_ session: KeepAwakeSession) -> KeepAwakeSession {
        var next = session
        next.pausedReason = nil
        return next
    }

    /// Whether the low-battery guard may re-arm the flag for this session:
    /// it must still be live (not due) AND belong to this boot. A session from
    /// a previous boot keeps its wall deadline so `isDue` can still end it, but
    /// re-arming the flag on a boot that never agreed to the session would
    /// resurrect a deadline nobody is watching — so it never re-arms.
    ///
    /// An indefinite session is the plain switch: ADR 022 governs it, on any
    /// boot, exactly as before sessions existed.
    public static func allowsRearm(_ session: KeepAwakeSession, now: Now) -> Bool {
        if session.isIndefinite { return true }
        return session.isOnBoot(now.bootID) && !isDue(session, now: now)
    }

    /// The record to keep when the operator turns the plain switch ON.
    ///
    /// A live timed session on this boot (typically one the low-battery guard
    /// paused) is RESUMED with its deadline: the switch must not silently turn
    /// "until 14:30" into "until I remember". Anything else (no record, an
    /// indefinite one, a due session, one from another boot) becomes a fresh
    /// indefinite session, the plain switch's shape.
    public static func recordAfterSwitchOn(existing: KeepAwakeSession?, now: Now) -> KeepAwakeSession {
        if let session = existing, !session.isIndefinite,
           session.isOnBoot(now.bootID), !isDue(session, now: now) {
            return resume(session)
        }
        return KeepAwakeSession(startedAt: now.wall, bootID: now.bootID)
    }

    // MARK: — Presentation

    /// `"2 h 41 left"` / `"8 min left"` / `"< 1 min left"`, nil for an
    /// indefinite session. Pure, so the menu bar and the CLI agree.
    public static func remainingLabel(_ session: KeepAwakeSession, now: Now) -> String? {
        guard let seconds = remaining(session, now: now) else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 0 { return "< 1 min left" }
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) min left" }
        if m == 0 { return "\(h) h left" }
        return "\(h) h \(m) left"
    }

    /// `"2h41"` / `"2h"` / `"45m"` / `"<1m"`: the menu-bar title, which has no
    /// room for words. Digits and unit letters read the same in English and
    /// French, so this needs no localization.
    public static func compactRemainingLabel(_ session: KeepAwakeSession, now: Now) -> String? {
        guard let seconds = remaining(session, now: now) else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 0 { return "<1m" }
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return String(format: "%dh%02d", h, m)
    }

    /// `"Until 14:30 · 2 h 41 left"` — the lid row's session line.
    public static func rowLabel(
        _ session: KeepAwakeSession,
        now: Now,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String? {
        guard let endsAtWall = session.endsAtWall else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        let until = formatter.string(from: endsAtWall)
        guard let left = remainingLabel(session, now: now) else {
            return "Until \(until)"
        }
        return "Until \(until) · \(left)"
    }
}

/// Parsing for `runclosed session start --for <2h|90m>` (ADR 023).
/// Deliberately tiny and dependency-free (ADR 003): `90m`, `2h`, `1h30m`,
/// `45`, `45s`. A bare number means MINUTES, matching how people say
/// "start a 90 minutes session".
public enum SessionDuration {
    /// The one extension step the popup and the CLI share.
    public static let extendStep: TimeInterval = 30 * 60

    /// The popup's duration buttons, in seconds.
    public static let presets: [TimeInterval] = [3600, 2 * 3600, 4 * 3600, 8 * 3600]

    /// Longest session we accept: 7 days. Not a product opinion about how long
    /// a Mac should stay awake — a bound, so an absurd `--for 999999999999h`
    /// is a usage error (exit 64) instead of an overflow, a trapped
    /// conversion, or a deadline so far out it is indistinguishable from
    /// "never". The popup only ever offers 8 h.
    public static let maximum: TimeInterval = 7 * 24 * 3600

    /// Whether a requested duration is usable at all.
    public static func isAcceptable(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds > 0 && seconds <= maximum
    }

    /// A deadline value safe to store, whatever the caller asked for.
    public static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(seconds, maximum)
    }

    /// `nil` = not parseable (the caller exits 64 with the usage line).
    /// What `runclosed session start` was asked to do.
    public enum StartArguments: Equatable, Sendable {
        case timed(TimeInterval)
        case indefinite
    }

    /// Why `session start` arguments were refused. Both exit 64, before any
    /// lock or write.
    public enum StartArgumentError: Error, Equatable, Sendable {
        /// Unknown flag, missing or unreadable value, or neither/both of
        /// `--for` and `--indefinite`.
        case usage
        /// `--for` longer than `maximum`.
        case overCap
    }

    /// Parse `session start` arguments. Pure, so the refusals are tested
    /// without a binary that could touch the real flag. `--for` together with
    /// `--indefinite` is a usage error: guessing which one the caller meant
    /// would start a session they did not ask for.
    public static func parseStartArguments(_ args: [String]) -> Result<StartArguments, StartArgumentError> {
        var duration: TimeInterval?
        var indefinite = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--for":
                i += 1
                guard i < args.count, let parsed = parse(args[i]) else { return .failure(.usage) }
                guard isAcceptable(parsed) else { return .failure(.overCap) }
                duration = parsed
            case "--indefinite":
                indefinite = true
            default:
                return .failure(.usage)
            }
            i += 1
        }
        switch (duration, indefinite) {
        case (let d?, false): return .success(.timed(d))
        case (nil, true): return .success(.indefinite)
        default: return .failure(.usage)
        }
    }

    public static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        var total: Double = 0
        var digits = ""
        /// Unit of the last group consumed, so a trailing bare number inherits
        /// the next-smaller unit: `1h30` = 90 min, `1h30m` = 90 min, `90` =
        /// 90 min (bare numbers are minutes by convention).
        var lastUnit: Character?

        func flush(_ multiplier: Double) -> Bool {
            guard let value = Double(digits) else { return false }
            total += value * multiplier
            digits = ""
            return true
        }

        for ch in trimmed {
            if ch.isNumber || ch == "." {
                digits.append(ch)
                continue
            }
            guard !digits.isEmpty else { return nil }
            switch ch {
            case "h": if !flush(3600) { return nil }
            case "m": if !flush(60) { return nil }
            case "s": if !flush(1) { return nil }
            default: return nil
            }
            lastUnit = ch
        }
        if !digits.isEmpty {
            let multiplier: Double
            switch lastUnit {
            case "h"?: multiplier = 60      // "1h30" → +30 min
            case "m"?: multiplier = 1       // "1m30" → +30 s
            case "s"?: multiplier = 1
            default: multiplier = 60        // bare "90" → 90 min
            }
            if !flush(multiplier) { return nil }
        }
        guard total > 0 else { return nil }
        return total
    }
}
