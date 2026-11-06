import Foundation

// ADR 023 — a timed keep-awake session.
//
// Before this, `pmset disablesleep 1` had no end time: the operator had to
// remember to switch it off, and the low-battery guard was the only thing
// standing between a forgotten switch and a dead battery. A session gives the
// flag a deadline, visible in the menu bar, enforced by the same tick that
// already owns the flag.
//
// The record is deliberately CLI-readable: `runclosed session status --json`
// prints it verbatim, so a future launchd recovery backstop (L2), a thermal
// guard (L3) and lid-close actions (L4) can consume one shared state instead
// of inventing their own.

public let kKeepAwakeSessionSchemaVersion = 1

/// Why a session stopped keeping the Mac awake without ending.
///
/// A pause is NOT an end: the session keeps its deadline and its identity, and
/// the low-battery guard may re-arm the flag when its hysteresis is satisfied.
public enum SessionPauseReason: String, Codable, Sendable, Equatable {
    /// The low-battery guard released the flag (ADR 022). The session survives
    /// so the operator's deadline is not lost to a battery episode.
    case lowBattery
}

/// A keep-awake session: the record that gives `disablesleep` an end time.
///
/// `endsAt == nil` (both deadlines nil) means an INDEFINITE session — exactly
/// today's plain switch. That is what keeps the existing behaviour byte-for-
/// byte identical: turning the switch on creates an indefinite session,
/// turning it off ends it.
public struct KeepAwakeSession: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int
    public var id: UUID
    public var startedAt: Date
    /// Wall-clock deadline. Survives a reboot and a wall-clock change; the
    /// cross-boot truth.
    public var endsAtWall: Date?
    /// `mach_continuous_time` nanoseconds. Monotonic AND keeps counting while
    /// the machine sleeps, so a deadline set before a lid-closed night is
    /// honoured on wake. Only meaningful on `bootID` (the counter restarts at
    /// boot). Deliberately NOT `systemUptime`: that clock stops during sleep,
    /// which is exactly the window this feature runs in (see `Clock.swift`).
    public var endsAtContinuous: UInt64?
    public var bootID: String
    public var pausedReason: SessionPauseReason?

    public init(
        schemaVersion: Int = kKeepAwakeSessionSchemaVersion,
        id: UUID = UUID(),
        startedAt: Date,
        endsAtWall: Date? = nil,
        endsAtContinuous: UInt64? = nil,
        bootID: String,
        pausedReason: SessionPauseReason? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.startedAt = startedAt
        self.endsAtWall = endsAtWall
        self.endsAtContinuous = endsAtContinuous
        self.bootID = bootID
        self.pausedReason = pausedReason
    }

    /// No end time: the plain switch (ADR 023 keeps it as a session so every
    /// surface reports one shape).
    public var isIndefinite: Bool {
        endsAtWall == nil && endsAtContinuous == nil
    }

    public var isPaused: Bool { pausedReason != nil }

    /// Same boot as the caller — only then does `endsAtContinuous` mean
    /// anything (the counter restarts at boot).
    public func isOnBoot(_ bootID: String) -> Bool { self.bootID == bootID }

    /// Tolerant decoding: a key added by a later version (L2's backstop state,
    /// L4's lid actions) must not make an existing file decode as corrupt and
    /// silently drop a live deadline.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, startedAt, endsAtWall, endsAtContinuous, bootID, pausedReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? kKeepAwakeSessionSchemaVersion
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAtWall = try c.decodeIfPresent(Date.self, forKey: .endsAtWall)
        endsAtContinuous = try c.decodeIfPresent(UInt64.self, forKey: .endsAtContinuous)
        bootID = try c.decode(String.self, forKey: .bootID)
        pausedReason = try c.decodeIfPresent(SessionPauseReason.self, forKey: .pausedReason)
    }
}
