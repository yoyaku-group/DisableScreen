import Foundation

/// The machine's thermal pressure, as `ThermalPolicy` sees it.
///
/// Deliberately Foundation-free, exactly like `LowBatteryPolicy`: the policy is
/// unit-tested on every platform, and the mapping from
/// `ProcessInfo.thermalState` lives in `ThermalReadback` (MacSystem), which is
/// the only place that may know Foundation's spelling.
public enum ThermalState: String, Codable, Sendable, Equatable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    /// macOS is asking applications to reduce work. Nothing to protect yet.
    public var isSerious: Bool { self == .serious }

    /// macOS is asking applications to stop. This is the emergency.
    public var isCritical: Bool { self == .critical }

    /// Either of the two states the guard has an opinion about.
    public var isHot: Bool { isSerious || isCritical }
}

/// Pure thermal safety policy for the lid stay-awake flag (ADR 025).
///
/// Why it exists: `pmset disablesleep 1` also blocks macOS's own emergency
/// sleep. The low-battery guard (ADR 022) covers the battery drain and the
/// recovery backstop (ADR 024) covers a crashed app — nothing covered HEAT. A
/// Mac sitting with the lid closed under a fleet of agents can run hot with
/// nothing cooling it: the panel is off, the workload continues, and macOS
/// cannot sleep the machine to cool it. That is the second half of the
/// 2026-10-14 incident.
///
/// The rule is one-directional and protective only: when the machine is hot and
/// nothing is cooling it, release the flag and let it sleep. There is
/// deliberately NO "enable" case — the ADR 022 re-arm belongs to the app, and a
/// rule that could turn the flag ON could keep a Mac awake to cook.
///
/// Mirrors `LowBatteryPolicy`'s shape: `(Input, Latch) -> (Decision, Latch)`,
/// no I/O, no mutation, no clock of its own (the caller passes `monotonic`).
public enum ThermalPolicy {

    /// How long `serious` has to hold — with nothing cooling the machine —
    /// before the guard stops waiting and lets the Mac sleep. A transient
    /// `serious` during a compile is normal and must not end a session; ten
    /// minutes of it, lid closed, no display, is not.
    public static let sustainedReleaseSeconds: TimeInterval = 10 * 60

    // MARK: — Inputs

    /// One observation. Every optional is genuinely optional: UNKNOWN is never
    /// coerced into a value (ADR 009), and the two independent refusals (lid
    /// open, display attached) are modelled as data so the policy — not the
    /// caller — owns the conservative reading of a missing one.
    public struct Input: Equatable, Sendable {
        public var state: ThermalState
        /// `AppleClamshellState`: `true` closed, `false` open, `nil` unreadable.
        public var lidClosed: Bool?
        /// An online display that is not the built-in panel. `false` means the
        /// machine has NO path to cool through a display, which is the only
        /// case where heat is dangerous. `true` and `nil` both refuse the
        /// release: unknown counts as attached, so the doubt never releases.
        public var externalDisplayConnected: Bool?
        /// Observed `disablesleep` (`pmset -g`); `nil` = unknown (B1).
        public var lidFlag: Bool?
        public var ownership: LowBatteryPolicy.LidOwnership
        /// Seconds on a monotonic clock that survives a process restart (so a
        /// supervising app tick and a launchd backstop minute share one
        /// timeline). Only ever compared with itself, and only within `bootID`.
        public var monotonic: Double
        /// Invalidates `seriousSince` across a restart: a monotonic counter
        /// restarts at boot, so a timestamp from another boot means nothing.
        public var bootID: String

        public init(state: ThermalState, lidClosed: Bool?, externalDisplayConnected: Bool?,
                    lidFlag: Bool?, ownership: LowBatteryPolicy.LidOwnership,
                    monotonic: Double, bootID: String) {
            self.state = state
            self.lidClosed = lidClosed
            self.externalDisplayConnected = externalDisplayConnected
            self.lidFlag = lidFlag
            self.ownership = ownership
            self.monotonic = monotonic
            self.bootID = bootID
        }

        /// Is the machine actually unable to cool itself? Only a closed lid
        /// with no display attached qualifies — that is the single situation
        /// this policy is allowed to act on.
        public var isEnclosed: Bool {
            lidClosed == true && externalDisplayConnected == false
        }
    }

    // MARK: — Latch

    /// Persisted episode state. Same role as `LowBatteryPolicy.Latch`: it is
    /// what keeps the guard from notifying every 30 s, and what makes an
    /// episode a single event rather than a per-tick one.
    public struct Latch: Codable, Equatable, Sendable {
        /// The `serious` heads-up (or refusal) was shown for this episode.
        public var warnedSerious: Bool
        /// The `critical` alert was shown for this episode.
        public var warnedCritical: Bool
        /// When the current `serious` run started, on `seriousSinceBootID`'s
        /// monotonic clock. `nil` = not running.
        public var seriousSince: Double?
        public var seriousSinceBootID: String?
        /// This episode already released the flag for heat. Set from a VERIFIED
        /// release, cleared when the machine cools (episode over). The popup and
        /// the menu-bar title read it to say "Session ended — heat" after the
        /// session record itself is gone.
        public var releasedForHeat: Bool
        /// The identifier of a repeating release FAILURE already reported in
        /// this episode (`"<reason>:<error>"`).
        ///
        /// A persistently failing release — a revoked sudoers rule, a `pmset`
        /// that refuses in the app's context — holds the identical condition on
        /// every 30 s tick, so without this it would write 2 880 identical
        /// audit lines and notifications a day. Same once-per-episode discipline
        /// the ADR 024 backstop applies to its own repeating failures, and the
        /// same reason the battery latch carries `failedReleaseSleepTried`.
        /// Cleared when the machine cools, so a new episode always reports.
        public var reportedFailure: String?

        public init(warnedSerious: Bool = false, warnedCritical: Bool = false,
                    seriousSince: Double? = nil, seriousSinceBootID: String? = nil,
                    releasedForHeat: Bool = false, reportedFailure: String? = nil) {
            self.warnedSerious = warnedSerious
            self.warnedCritical = warnedCritical
            self.seriousSince = seriousSince
            self.seriousSinceBootID = seriousSinceBootID
            self.releasedForHeat = releasedForHeat
            self.reportedFailure = reportedFailure
        }

        private enum CodingKeys: String, CodingKey {
            case warnedSerious, warnedCritical, seriousSince, seriousSinceBootID, releasedForHeat,
                 reportedFailure
        }

        /// Tolerant decoding, like the battery latch: a key added by a later
        /// version must not make an existing file read as corrupt (which would
        /// reset an open episode and re-alert).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            warnedSerious = try c.decodeIfPresent(Bool.self, forKey: .warnedSerious) ?? false
            warnedCritical = try c.decodeIfPresent(Bool.self, forKey: .warnedCritical) ?? false
            seriousSince = try c.decodeIfPresent(Double.self, forKey: .seriousSince)
            seriousSinceBootID = try c.decodeIfPresent(String.self, forKey: .seriousSinceBootID)
            releasedForHeat = try c.decodeIfPresent(Bool.self, forKey: .releasedForHeat) ?? false
            reportedFailure = try c.decodeIfPresent(String.self, forKey: .reportedFailure)
        }

        /// Write-from-outcome (B3): set only after a readback-verified release.
        public func recordingRelease() -> Latch {
            var next = self
            next.releasedForHeat = true
            return next
        }
    }

    // MARK: — Outputs

    /// There is no `enable`. The absence is the rule: a protective policy that
    /// could turn the flag on would be able to keep a hot Mac awake.
    public enum Action: String, Codable, Sendable, Equatable {
        case none
        /// Tell the operator (no mutation).
        case warn
        /// Release `disablesleep` (ownership-gated) then `pmset sleepnow`.
        case releaseAndSleep
    }

    public enum Reason: String, Codable, Sendable, Equatable {
        case nominal
        case fair
        /// The flag is already off: macOS sleeps and cools on its own.
        case lidFlagOff
        /// B1 — a flag we cannot read is a flag we cannot release.
        case lidFlagUnknown
        /// The air circulates and the operator is there.
        case lidOpen
        /// Not `false`, and `false` is the only reading that proves the lid is
        /// shut (see `LidMutationPolicy`'s unknown-prior rule).
        case lidUnknown
        /// A display is attached: something is plugged in, and an external
        /// display implies the operator is using the machine.
        case externalDisplay
        /// B2 — the flag is set and not provably ours on this boot.
        case notOwned
        /// `serious`, nothing cooling it, the operator is told once.
        case seriousWarn
        /// `serious` held for `sustainedReleaseSeconds`.
        case seriousSustained
        /// `critical`, nothing cooling it, ours: release now.
        case criticalOwned
    }

    public struct Decision: Equatable, Sendable {
        public var action: Action
        public var reason: Reason
        public var state: ThermalState
        public init(action: Action, reason: Reason, state: ThermalState) {
            self.action = action
            self.reason = reason
            self.state = state
        }
    }

    // MARK: — Policy

    /// One evaluation tick. Returns the action to perform now and the latch to
    /// persist. `releasedForHeat` is only SET by the service from a verified
    /// outcome (`Latch.recordingRelease()`), exactly like the battery latch.
    public static func step(_ input: Input, latch: Latch) -> (decision: Decision, latch: Latch) {
        var next = latch
        // A monotonic timestamp is only meaningful on the boot that produced
        // it; a counter restarts at boot.
        if next.seriousSinceBootID != input.bootID {
            next.seriousSince = nil
            next.seriousSinceBootID = nil
        }

        guard input.state.isHot else {
            // The episode is over: every latch resets, including the heat
            // release — the next episode is a new event and must be able to
            // alert and release again (same discipline as the battery latch
            // clearing above its warn band).
            next = Latch()
            return (Decision(action: .none,
                             reason: input.state == .nominal ? .nominal : .fair,
                             state: input.state), next)
        }

        // A hot machine with the flag OFF is already as cool as it can get:
        // macOS's own thermal management sleeps and throttles freely.
        //
        // It also STOPS the sustained-heat clock, and that is not a detail: the
        // flag being off means the condition this rule exists for (we are
        // holding a hot machine awake) is over, so the ten minutes must
        // restart if it comes back. Without the clear, a session released for
        // heat, re-armed on AC, and still hot would be released again
        // immediately instead of getting its own grace period.
        if input.lidFlag == false {
            next.seriousSince = nil
            next.seriousSinceBootID = nil
            return (Decision(action: .none, reason: .lidFlagOff, state: input.state), next)
        }
        // B1: cannot release a flag we cannot observe.
        if input.lidFlag == nil {
            return refusal(.lidFlagUnknown, input: input, latch: &next)
        }

        // — The three refusals that make heat harmless. Checked in the order
        // the operator would reason about them: is there air, is there a
        // display, and are we even allowed to write.
        if input.lidClosed != true {
            return refusal(input.lidClosed == false ? .lidOpen : .lidUnknown,
                           input: input, latch: &next)
        }
        // `nil` (no display information) is NOT `false`: unknown counts as
        // attached, so the doubt never releases.
        if input.externalDisplayConnected != false {
            return refusal(.externalDisplay, input: input, latch: &next)
        }
        if input.ownership != .ownedThisBoot {
            // B2: a flag another tool set is never mutated — alert only. (A
            // stale record of ours is not active ownership either; the heat
            // rule has no emergency widening, unlike ADR 022's battery one.)
            return refusal(.notOwned, input: input, latch: &next)
        }

        // — Eligible: hot, enclosed, ours.
        if input.state.isCritical {
            return (Decision(action: .releaseAndSleep, reason: .criticalOwned,
                             state: input.state), next)
        }
        // `serious` gets a grace period so a compiler burst does not end a
        // session; the timer only advances while the release is actually
        // possible, so a machine that becomes enclosed at minute 9 releases at
        // minute 19, not immediately.
        let since: Double
        if let existing = next.seriousSince {
            since = existing
        } else {
            since = input.monotonic
            next.seriousSince = since
            next.seriousSinceBootID = input.bootID
        }
        if input.monotonic - since >= sustainedReleaseSeconds {
            return (Decision(action: .releaseAndSleep, reason: .seriousSustained,
                             state: input.state), next)
        }
        // `holdsClock: false`: this tick is INSIDE the grace period with the
        // release possible, so the timer keeps running.
        return refusal(.seriousWarn, input: input, latch: &next, holdsClock: false)
    }

    /// The machine is hot and this tick cannot release it. `critical` always
    /// says so once (the table's ".warn when it cannot act"); `serious` only
    /// says so when the operator can do something about it — the heads-up, and
    /// a flag that is not ours. `serious` with a display attached or the lid
    /// open stays silent: that is the ordinary shape of heavy work, not news.
    ///
    /// `holdsClock: false` is the ONE refusal that must not touch the
    /// sustained-heat timer: `.seriousWarn` is emitted from inside the grace
    /// period, on a tick where the release IS possible. Clearing there would
    /// restart the clock every tick and the guard would never release at all.
    private static func refusal(
        _ reason: Reason, input: Input, latch: inout Latch, holdsClock: Bool = true
    ) -> (decision: Decision, latch: Latch) {
        if holdsClock {
            // Ten minutes of heat that COULD be released, never ten minutes of
            // heat somewhere in the machine's past. Without this, a Mac that
            // ran `serious` for five minutes with the lid closed, sat open for
            // fifteen (cooling, the workload settling), and then closed again
            // released the instant the lid came down — ending the operator's
            // session on a spike that had already been cooled. The clock only
            // advances while a release is actually possible, which is what the
            // comment on `seriousSince` always claimed.
            latch.seriousSince = nil
            latch.seriousSinceBootID = nil
        }
        let notify: Bool
        if input.state.isCritical {
            notify = !latch.warnedCritical
            if notify { latch.warnedCritical = true }
        } else {
            switch reason {
            case .seriousWarn, .notOwned:
                notify = !latch.warnedSerious
                if notify { latch.warnedSerious = true }
            default:
                notify = false
            }
        }
        return (Decision(action: notify ? .warn : .none, reason: reason, state: input.state),
                latch)
    }
}
