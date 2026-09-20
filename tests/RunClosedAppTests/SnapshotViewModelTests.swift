import XCTest
@testable import RunClosedCore
@testable import RunClosedApp

// Pure presentation tests — no AppKit, no real system calls.
// These are the G2a regression guardrails for the three guarantees listed at
// the top of SnapshotViewModel.swift:
//   1. unknown power is never rendered as "off"
//   2. softwareDim is never rendered as "native"
//   3. leases from another bootID are filtered

final class SnapshotViewModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let boot = "B0001"

    private func snap(_ id: UInt32, builtin: Bool, backend: String,
                      brightness: CapabilityStatus = .supported,
                      mode: String = "1728x1117") -> DisplaySnapshot {
        DisplaySnapshot(
            identity: DisplayIdentity(displayID: id, isBuiltin: builtin, localizedName: "d-\(id)"),
            capability: DisplayCapability(brightness: brightness,
                                          brightnessBackend: backend,
                                          deactivate: builtin ? .experimental : .supported),
            currentMode: mode)
    }

    // MARK: - ADR 009 invariant: UNKNOWN != OFF

    func testLidUnknownIsNeverRenderedAsOff() {
        let vm = SnapshotBuilder.make(now: now, snapshots: [],
                                      lidStayAwake: nil, leases: [],
                                      currentBootID: boot)
        XCTAssertEqual(vm.lidStayAwake, .unknown)
        let text = SnapshotRenderer.render(vm)
        XCTAssertTrue(text.contains("state unknown"),
                      "UNKNOWN power must render its own copy, not collapse to off")
        XCTAssertFalse(text.contains("standard sleep posture"),
                       "UNKNOWN power must never be rendered as OFF")
    }

    func testLidOnRendersOn() {
        let vm = SnapshotBuilder.make(now: now, snapshots: [], lidStayAwake: true,
                                      leases: [], currentBootID: boot)
        XCTAssertEqual(vm.lidStayAwake, .on)
        XCTAssertTrue(SnapshotRenderer.render(vm).contains("keep awake on lid close"))
    }

    func testLidOffRendersOff() {
        let vm = SnapshotBuilder.make(now: now, snapshots: [], lidStayAwake: false,
                                      leases: [], currentBootID: boot)
        XCTAssertEqual(vm.lidStayAwake, .off)
        XCTAssertTrue(SnapshotRenderer.render(vm).contains("standard sleep posture"))
    }

    // MARK: - Capability honesty: softwareDim never labelled "native"

    func testSoftwareDimBackendNeverLabeledNative() {
        let s = snap(1, builtin: false, backend: "softwareDim")
        let vm = SnapshotBuilder.make(now: now, snapshots: [s],
                                      lidStayAwake: false, leases: [],
                                      currentBootID: boot)
        let text = SnapshotRenderer.render(vm)
        XCTAssertTrue(text.contains("softwareDim"))
        XCTAssertFalse(text.contains("native"),
                       "An external display with softwareDim backend must not be rendered 'native'")
    }

    func testBuiltinNativeBackendLabeledNative() {
        let s = snap(2, builtin: true, backend: "native")
        let vm = SnapshotBuilder.make(now: now, snapshots: [s],
                                      lidStayAwake: false, leases: [],
                                      currentBootID: boot)
        XCTAssertTrue(SnapshotRenderer.render(vm).contains("native"))
    }

    func testBrightnessUnknownRendersUnknown() {
        let s = snap(3, builtin: false, backend: "none",
                     brightness: .unknown)
        let vm = SnapshotBuilder.make(now: now, snapshots: [s],
                                      lidStayAwake: false, leases: [],
                                      currentBootID: boot)
        XCTAssertTrue(SnapshotRenderer.render(vm).contains("brightness: unknown"))
    }

    // MARK: - Leases filtered by bootID (defence in depth)

    func testLeasesFromOtherBootFiltered() {
        let live = Lease(id: "L1", owner: "cli", sessionID: "s1", pid: 42,
                         bootID: boot,
                         workSource: .wrapper, state: .working,
                         requestedIdleSleep: true, requestedClosedLid: false,
                         deadlineMonotonic: 1.0)
        let stale = Lease(id: "L2", owner: "old-cli", sessionID: "s2", pid: 7,
                           bootID: "OTHER-BOOT",
                           workSource: .wrapper, state: .working,
                           requestedIdleSleep: true, requestedClosedLid: false,
                           deadlineMonotonic: 1.0)
        let vm = SnapshotBuilder.make(now: now, snapshots: [],
                                      lidStayAwake: false, leases: [live, stale],
                                      currentBootID: boot)
        XCTAssertEqual(vm.leases.count, 1, "Leases from a different bootID must be filtered")
        XCTAssertEqual(vm.leases.first?.id, "L1")
        XCTAssertFalse(SnapshotRenderer.render(vm).contains("old-cli"))
    }

    func testNoLeasesRendersNone() {
        let vm = SnapshotBuilder.make(now: now, snapshots: [],
                                      lidStayAwake: false, leases: [],
                                      currentBootID: boot)
        XCTAssertTrue(SnapshotRenderer.render(vm).contains("Active sessions: none"))
    }

    // MARK: - Display rows

    func testAmbiguousDisplayFlagged() {
        let a = snap(10, builtin: false, backend: "softwareDim")
        let b = snap(11, builtin: false, backend: "softwareDim")
        // Force same localisedName so the ambiguity detector triggers
        let a2 = DisplaySnapshot(
            identity: DisplayIdentity(displayID: 10, isBuiltin: false, localizedName: "Same"),
            capability: a.capability, currentMode: a.currentMode)
        let b2 = DisplaySnapshot(
            identity: DisplayIdentity(displayID: 11, isBuiltin: false, localizedName: "Same"),
            capability: b.capability, currentMode: b.currentMode)
        let vm = SnapshotBuilder.make(now: now, snapshots: [a2, b2],
                                      lidStayAwake: false, leases: [],
                                      currentBootID: boot)
        XCTAssertTrue(vm.displays.allSatisfy { $0.ambiguous })
        XCTAssertTrue(SnapshotRenderer.render(vm).contains("ambiguous"))
    }

    func testNoDisplaysRendersEmpty() {
        let vm = SnapshotBuilder.make(now: now, snapshots: [],
                                      lidStayAwake: false, leases: [],
                                      currentBootID: boot)
        XCTAssertTrue(SnapshotRenderer.render(vm).contains("Displays: none"))
    }

    // MARK: - Stability: renderer output is stable for stable input

    func testRendererIsDeterministic() {
        let s = snap(7, builtin: true, backend: "native")
        let l = Lease(id: "L", owner: "cli", sessionID: "s", pid: 1,
                      bootID: boot, workSource: .wrapper, state: .working,
                      requestedIdleSleep: true, requestedClosedLid: false,
                      deadlineMonotonic: 1.0)
        let vm1 = SnapshotBuilder.make(now: now, snapshots: [s],
                                       lidStayAwake: true, leases: [l],
                                       currentBootID: boot)
        let vm2 = SnapshotBuilder.make(now: now, snapshots: [s],
                                       lidStayAwake: true, leases: [l],
                                       currentBootID: boot)
        XCTAssertEqual(SnapshotRenderer.render(vm1), SnapshotRenderer.render(vm2))
    }
}
