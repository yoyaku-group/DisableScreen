import XCTest
@testable import RunClosedCore

/// The lid-close action policy (ADR 026), pure. Every refusal is a test rather
/// than a claim, and the three conditions are each proven necessary.
final class LidCloseActionPolicyTests: XCTestCase {

    private func input(sessionActive: Bool = true,
                       lidClosed: Bool? = true,
                       externalDisplay: Bool? = false,
                       enabled: Bool = true,
                       muteAudio: Bool = true,
                       pauseApps: Bool = false,
                       apps: [String] = ["Slack", "Discord", "WhatsApp"])
        -> LidCloseActionPolicy.Input {
        LidCloseActionPolicy.Input(
            sessionActive: sessionActive,
            lidClosed: lidClosed,
            externalDisplayConnected: externalDisplay,
            settings: LidCloseActionSettings(enabled: enabled, muteAudio: muteAudio,
                                             pauseApps: pauseApps, pausedApps: apps))
    }

    // MARK: — The three conditions

    func testAllThreeConditionsApply() {
        let d = LidCloseActionPolicy.decide(input(), currentlyApplied: false)
        XCTAssertEqual(d.action, .apply)
        XCTAssertEqual(d.reason, .applied)
        XCTAssertTrue(d.muteAudio)
        XCTAssertFalse(d.pauseApps, "the app pause is its own switch, off by default")
    }

    /// Each condition on its own is necessary: removing it refuses.
    func testEachConditionIsNecessary() {
        XCTAssertEqual(
            LidCloseActionPolicy.decide(input(sessionActive: false), currentlyApplied: false).reason,
            .noSession)
        XCTAssertEqual(
            LidCloseActionPolicy.decide(input(lidClosed: false), currentlyApplied: false).reason,
            .lidOpen)
        XCTAssertEqual(
            LidCloseActionPolicy.decide(input(externalDisplay: true), currentlyApplied: false).reason,
            .externalDisplay)
    }

    /// The rule that protects a docked workstation: an attached display refuses
    /// even with the lid closed and a session running.
    func testExternalDisplayNeverActs() {
        let d = LidCloseActionPolicy.decide(
            input(lidClosed: true, externalDisplay: true), currentlyApplied: false)
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .externalDisplay)
    }

    /// UNKNOWN is never `true` (ADR 009): an unreadable lid refuses.
    func testUnknownLidRefuses() {
        XCTAssertEqual(
            LidCloseActionPolicy.decide(input(lidClosed: nil), currentlyApplied: false).reason,
            .lidUnknown)
    }

    /// UNKNOWN counts as ATTACHED: the doubt never touches the machine.
    func testUnknownDisplayCountsAsAttached() {
        let d = LidCloseActionPolicy.decide(
            input(externalDisplay: nil), currentlyApplied: false)
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .displayUnknown)
    }

    /// The operator's master switch, OFF by default.
    func testSwitchedOffByDefaultDoesNothing() {
        XCTAssertFalse(LidCloseActionSettings().enabled)
        let d = LidCloseActionPolicy.decide(
            input(enabled: false), currentlyApplied: false)
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(d.reason, .switchedOff)
    }

    /// The switch is checked FIRST: an operator who turned it off must read
    /// "switched off", not "no session".
    func testSwitchReasonIsNotMaskedByOtherRefusals() {
        let d = LidCloseActionPolicy.decide(
            input(sessionActive: false, lidClosed: false, externalDisplay: true, enabled: false),
            currentlyApplied: false)
        XCTAssertEqual(d.reason, .switchedOff)
    }

    // MARK: — Session shapes

    /// An INDEFINITE session counts as "a session is in progress": the plan
    /// says a session, not a timed session.
    func testIndefiniteSessionCountsAsActive() {
        let indefinite = KeepAwakeSession(startedAt: Date(), bootID: "A")
        XCTAssertTrue(indefinite.isIndefinite)
        XCTAssertTrue(LidCloseActionPolicy.sessionIsActive(indefinite))
    }

    func testTimedSessionIsActive() {
        let timed = KeepAwakeSession(startedAt: Date(), endsAtWall: Date().addingTimeInterval(600),
                                     bootID: "A")
        XCTAssertTrue(LidCloseActionPolicy.sessionIsActive(timed))
    }

    /// A PAUSED session is not being kept awake, so there is nothing to make
    /// comfortable.
    func testPausedSessionIsNotActive() {
        let paused = KeepAwakeSession(startedAt: Date(), bootID: "A", pausedReason: .lowBattery)
        XCTAssertFalse(LidCloseActionPolicy.sessionIsActive(paused))
    }

    func testNoSessionIsNotActive() {
        XCTAssertFalse(LidCloseActionPolicy.sessionIsActive(nil))
    }

    // MARK: — The undo direction

    /// The conditions stopping is what triggers the undo — and only when
    /// something was actually applied.
    func testConditionsStoppingWithSomethingAppliedUndoes() {
        for refusal in [input(sessionActive: false), input(lidClosed: false),
                        input(externalDisplay: true), input(enabled: false)] {
            let d = LidCloseActionPolicy.decide(refusal, currentlyApplied: true)
            XCTAssertEqual(d.action, .undo, "reason=\(d.reason)")
        }
    }

    /// Nothing applied + conditions not holding = nothing at all. No error, no
    /// double effect: a lid closed twice is idempotent.
    func testNothingAppliedAndConditionsStopIsANoOp() {
        let d = LidCloseActionPolicy.decide(input(lidClosed: false), currentlyApplied: false)
        XCTAssertEqual(d.action, .none)
    }

    /// With everything applied and the conditions still holding, the decision is
    /// still `.apply`: the step is idempotent, and the service never re-mutes a
    /// device or re-signals a process because the journal already holds them.
    func testConditionsHoldingWithSomethingAppliedStillApplies() {
        let d = LidCloseActionPolicy.decide(input(), currentlyApplied: true)
        XCTAssertEqual(d.action, .apply)
    }

    // MARK: — App list

    /// The plan's defaults, and the app list is only passed through when the
    /// app-pause switch is on.
    func testPausedAppsDefaultsAndGating() {
        XCTAssertEqual(LidCloseActionSettings.defaultPausedApps, ["Slack", "Discord", "WhatsApp"])
        XCTAssertTrue(LidCloseActionPolicy.decide(input(), currentlyApplied: false).appNames.isEmpty,
                      "no app names when the app pause is off")
        XCTAssertEqual(
            LidCloseActionPolicy.decide(input(pauseApps: true), currentlyApplied: false).appNames,
            ["Slack", "Discord", "WhatsApp"])
    }

    // MARK: — Settings decoding

    func testSettingsDefaultsAreOff() {
        let s = LidCloseActionSettings()
        XCTAssertFalse(s.enabled)
        XCTAssertTrue(s.muteAudio)
        XCTAssertFalse(s.pauseApps)
        XCTAssertEqual(s.pausedApps, ["Slack", "Discord", "WhatsApp"])
    }

    /// A key added by a later version must not make the stored settings read as
    /// corrupt — which would silently fall back to OFF and disable a feature the
    /// operator turned on.
    func testSettingsDecodingToleratesAMissingKey() throws {
        let json = Data(#"{"enabled":true,"pauseApps":true}"#.utf8)
        let s = try JSONDecoder().decode(LidCloseActionSettings.self, from: json)
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.pauseApps)
        XCTAssertTrue(s.muteAudio, "absent key falls back to the default, not to false")
        XCTAssertEqual(s.pausedApps, ["Slack", "Discord", "WhatsApp"])
    }

    /// An exhaustive sweep: no combination of the six readings asks for an
    /// apply while any condition is missing. 3 × 3 × 2 × 2 × 2 × 2 = 144 cases.
    func testNoCombinationActsWithoutAllThreeConditions() {
        for sessionActive in [true, false] {
            for lid in [Bool?.some(true), .some(false), .none] {
                for display in [Bool?.some(true), .some(false), .none] {
                    for enabled in [true, false] {
                        for mute in [true, false] {
                            for pause in [true, false] {
                                let i = input(sessionActive: sessionActive, lidClosed: lid,
                                              externalDisplay: display, enabled: enabled,
                                              muteAudio: mute, pauseApps: pause)
                                let d = LidCloseActionPolicy.decide(i, currentlyApplied: false)
                                let conditions = sessionActive && lid == true && display == false
                                if !enabled || !conditions {
                                    XCTAssertNotEqual(d.action, .apply,
                                                      "acted without the conditions: \(i)")
                                } else {
                                    XCTAssertEqual(d.action, .apply)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// And the symmetric sweep: with something applied, an apply is only ever
    /// asked for while every condition holds — otherwise the answer is `undo`.
    func testUndoIsAskedWheneverConditionsStopWithSomethingApplied() {
        for lid in [Bool?.some(true), .some(false), .none] {
            for display in [Bool?.some(true), .some(false), .none] {
                for enabled in [true, false] {
                    let i = input(lidClosed: lid, externalDisplay: display, enabled: enabled)
                    let d = LidCloseActionPolicy.decide(i, currentlyApplied: true)
                    let conditions = lid == true && display == false && enabled
                    XCTAssertEqual(d.action, conditions ? .apply : .undo,
                                   "lid=\(String(describing: lid)) display=\(String(describing: display)) enabled=\(enabled)")
                }
            }
        }
    }
}
