import AppKit
import RunClosedCore
import RunClosedMacSystem
import RunClosedPersistence
import RunClosedApp

// G2d — menu-bar app, MUTATING (supersedes the G2a read-only tranche).
//
// Surface: one status item → NSPanel popup with NSSwitch toggles, a
// brightness slider, a resolution dropdown, a lid stay-awake switch, a login
// item switch and Quit — feature parity with the Python DisableScreen panel
// it replaces (the layout constants are a direct port).
//
// Mutation safety (all invariants carried over from the Python app + the
// engine tranches):
// - Display disable/enable routes through DisplayMutationService: policy
//   re-checked at the moment of the effect (A04), last-active refused,
//   owned ids persisted + re-enable attempted at launch (B3).
// - Lid stay-awake routes through LidMutationService: UNKNOWN prior refuses
//   (B1), setting OFF requires ownership proven by readback (B2), no
//   unconditional restore on quit, cross-boot record kept fail-closed (ADR 015).
// - Brightness targets ONE display (invariant 1): builtin → native
//   CoreDisplay write; external → software dim overlay floored at 0.08.
// - Reads are off-main (A09); the panel is rebuilt on main from cached state.
//
// The menu stays available on right-click for the CLI-parity surfaces
// (leases detail, refresh) — the popup is the primary surface.

@main
struct RunClosedMenuBarApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

typealias DisplayCard = PopupState.DisplayCard

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: PopupPanel?
    private var refreshTimer: Timer?
    private var screensTimer: Timer?
    private var globalMonitor: Any?
    private var busy = false

    private let dim = DimOverlayController()
    private let clock = SystemClock(bootID: BootID.current())

    /// Cached lid state — refreshed off-main by the shared status probe.
    private var lidCache: Bool??
    private var lidReady = false

    // MARK: — Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Launch recovery: re-enable displays we owned, reconcile the lid
        // record (never auto-restore across boots — ADR 015).
        recoverAtLaunch()
        refreshLidCache()
        updateStatusIcon()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLidCache() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        var displayService = makeDisplayService()
        _ = displayService.restoreOwned()
        // Lid: restore ONLY if we own it on this boot (B2/ADR 015).
        var lidService = makeLidService()
        _ = lidService.restoreIfOwned()
    }

    @objc private func screensChanged() {
        screensTimer?.invalidate()
        screensTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
                self?.rebuildPanelIfVisible()
            }
        }
    }

    // MARK: — Services

    private func makeDisplayService() -> DisplayMutationService {
        DisplayMutationService(
            bootID: clock.bootID,
            mutator: DisplayMutators.live(),
            store: OwnedDisabledDisplays(currentBootID: clock.bootID),
            activeIDsProvider: { DisplayInventory.activeIDs() }
        )
    }

    private func makeLidService() -> LidMutationService {
        LidMutationService(
            bootID: clock.bootID,
            mutator: LidAssertions.live(),
            store: OwnedLidAssertion(currentBootID: clock.bootID),
            priorProvider: { PowerReadback.lidStayAwake() }
        )
    }

    private func recoverAtLaunch() {
        let bootID = clock.bootID
        DispatchQueue.global(qos: .utility).async { [weak self, bootID] in
            var displayService = DisplayMutationService(
                bootID: bootID,
                mutator: DisplayMutators.live(),
                store: OwnedDisabledDisplays(currentBootID: bootID),
                activeIDsProvider: { DisplayInventory.activeIDs() }
            )
            let stillOwned = displayService.restoreOwned()
            var lidService = LidMutationService(
                bootID: bootID,
                mutator: LidAssertions.live(),
                store: OwnedLidAssertion(currentBootID: bootID),
                priorProvider: { PowerReadback.lidStayAwake() }
            )
            let outcome = lidService.reconcileCrossBoot()
            DispatchQueue.main.async {
                self?.updateStatusIcon()
                if !stillOwned.isEmpty || outcome != .currentBoot {
                    FileHandle.standardError.write(Data(
                        "[RunClosed] launch recovery (boot \(bootID)): displays still owned=\(stillOwned), lid=\(outcome)\n".utf8))
                }
            }
        }
    }

    private func refreshLidCache() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = PowerReadback.lidStayAwake()
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.lidCache != value
                self.lidCache = .some(value)
                self.lidReady = true
                if changed { self.rebuildPanelIfVisible() }
            }
        }
    }

    // MARK: — Status item

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { togglePanel(); return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func updateStatusIcon() {
        let disabledCount = OwnedDisabledDisplays(currentBootID: clock.bootID).load().ids.count
        let symbol = disabledCount > 0 ? "display.slash" : "laptopcomputer"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusItem.button?.image?.isTemplate = true
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Rafraîchir", action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Réglages Écran macOS", action: #selector(openDisplaysSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter RunClosed", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore popup behavior for left-click
    }

    @objc private func refreshClicked(_ sender: Any?) {
        refreshLidCache()
        updateStatusIcon()
        rebuildPanelIfVisible()
    }

    // MARK: — Panel

    private func togglePanel() {
        if panel != nil { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        let state = assembleState()
        let (view, height) = PopupPanel.buildContent(state, target: self)
        let p = PopupPanel.create()
        p.onDismiss = { [weak self] in self?.hidePanel() }
        p.contentView = view
        p.setFrame(NSMakeRect(0, 0, PopupPanel.width, height), display: false)

        if let button = statusItem.button, let btnWindow = button.window {
            let frameInScreen = btnWindow.convertToScreen(button.frame)
            let screen = btnWindow.screen ?? NSScreen.main
            var x = frameInScreen.midX - PopupPanel.width / 2
            if let sf = screen?.frame {
                x = max(sf.minX + 8, min(x, sf.maxX - PopupPanel.width - 8))
            }
            var top = frameInScreen.minY - 2
            if let sf = screen?.frame {
                top = min(top, sf.maxY - 2)
                top = max(top, sf.minY + height + 2)
            }
            p.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        }
        p.makeKeyAndOrderFront(nil)
        panel = p

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            if event.window != panel { self.hidePanel() }
        }
    }

    private func hidePanel() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }

    private func rebuildPanelIfVisible() {
        guard panel != nil else { return }
        hidePanel()
        showPanel()
    }

    // MARK: — State assembly

    private func assembleState() -> PopupState {
        let snapshots = DisplayInventory.snapshot()
        let activeIDs = DisplayInventory.activeIDs()
        let ownedRec = OwnedDisabledDisplays(currentBootID: clock.bootID)
        let ownedIDs = ownedRec.load().ids

        // Include displays we own as disabled (they vanish from the CG online
        // list once off, but we must still render their card to re-enable).
        var allIDs = activeIDs
        for id in ownedIDs where !allIDs.contains(id) { allIDs.append(id) }

        let lidValue: Bool? = {
            guard lidReady, let cached = lidCache else { return nil }
            return cached
        }()
        let lidState: SnapshotViewModel.PowerState = {
            guard let v = lidValue else { return .unknown }
            return v ? .on : .off
        }()

        let cards: [DisplayCard] = allIDs.map { id in
            let snap = snapshots.first { $0.identity.displayID == id }
            let builtin = snap?.identity.isBuiltin ?? (CGDisplayIsBuiltin(id) != 0)
            let isDisabled = ownedIDs.contains(id) || !activeIDs.contains(id)
            let name = builtin
                ? "Écran intégré"
                : (snap?.identity.localizedName ?? "Écran \(id)")
            let resolution = isDisabled ? "-" : DisplayModes.currentLabel(displayID: id)

            var brightness: Double?
            var floor = DimOverlayController.floor
            if !isDisabled {
                if builtin {
                    brightness = DisplayBrightness.get(builtin: id)
                } else {
                    brightness = dim.current(displayID: id)
                    floor = dim.current(displayID: id)   // slider floor == overlay floor
                }
            }

            let modes = isDisabled ? [] : DisplayModes.available(displayID: id)
            let selected: Int? = {
                guard !isDisabled, let cur = DisplayModes.current(displayID: id) else { return nil }
                return DisplayModeSelection.index(in: modes, width: cur.width, height: cur.height)
            }()

            let canToggle: Bool = {
                if isDisabled { return true }                 // always offer re-enable
                // Backend must support deactivation at all (builtin =
                // experimental on this hardware) AND the last-active guard
                // must allow it right now. Python parity: the switch is greyed
                // when this is the only active display.
                let backendCan = snap?.capability.deactivate != .unsupported
                return backendCan && DisplayMutationPolicy.canDisable(target: id, activeIDs: activeIDs)
            }()

            return DisplayCard(
                id: id,
                name: name,
                builtin: builtin,
                resolution: resolution,
                brightness: brightness,
                brightnessFloor: floor,
                isDisabled: isDisabled,
                canToggle: canToggle,
                modes: modes,
                selectedModeIndex: selected,
                ambiguous: snap?.identity.ambiguous ?? false
            )
        }.sorted { a, b in
            if a.builtin != b.builtin { return a.builtin }
            return a.id < b.id
        }

        let leases = LeaseStore(clock: clock).load().leases
        let summary: String? = leases.isEmpty
            ? nil
            : "Sessions actives (\(leases.count)) : " + leases.map(\.owner).joined(separator: ", ")

        return PopupState(
            displays: cards,
            lid: lidState,
            lidCanToggle: lidValue != nil,
            lidPending: false,
            loginItemEnabled: LoginItemControl.isEnabled(),
            loginItemAvailable: LoginItemControl.isActionable(),
            leasesSummary: summary,
            busy: busy
        )
    }

    // MARK: — Actions

    @objc func toggleDisplay(_ sender: NSSwitch) {
        let id = UInt32(sender.tag)
        withBusy {
            var service = self.makeDisplayService()
            let currentlyDisabled = OwnedDisabledDisplays(currentBootID: self.clock.bootID)
                .load().ids.contains(id) || !DisplayInventory.activeIDs().contains(id)
            if currentlyDisabled {
                let result = service.enable(target: id)
                self.log(result: result, what: "enable \(id)")
                self.dim.clear(displayID: id)
            } else {
                let result = service.disable(target: id)
                self.log(result: result, what: "disable \(id)")
            }
            self.updateStatusIcon()
        }
    }

    @objc func adjustBrightness(_ sender: NSSlider) {
        let id = UInt32(sender.tag)
        let value = sender.doubleValue
        let builtin = CGDisplayIsBuiltin(id) != 0
        if builtin {
            _ = DisplayBrightness.set(builtin: id, value: value)
        } else {
            if let applied = dim.apply(displayID: id, value: value) {
                sender.doubleValue = applied
            }
        }
        if let label = panel?.contentView?.viewWithTag(Int(id) + 100_000) as? NSTextField {
            label.stringValue = "\(Int(sender.doubleValue * 100))%"
        }
    }

    @objc func changeResolution(_ sender: NSPopUpButton) {
        let id = UInt32(sender.tag)
        let modes = DisplayModes.available(displayID: id)
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < modes.count else { return }
        let mode = modes[index]
        withBusy {
            let result = DisplayModes.set(displayID: id, width: mode.width, height: mode.height)
            if result.state != .verified {
                FileHandle.standardError.write(Data(
                    "[RunClosed] resolution \(id) → \(mode.label) FAILED: \(result.error ?? "-")\n".utf8))
            }
        }
    }

    @objc func toggleLid(_ sender: NSSwitch) {
        guard let current = lidCache, let value = current else { return }
        let target = !value
        withBusy {
            var service = self.makeLidService()
            let result = service.setEnabled(target)
            self.log(result: result, what: "lid -> \(target)")
            self.refreshLidCache()
        }
    }

    @objc func toggleLoginItem(_ sender: NSSwitch) {
        let target = !LoginItemControl.isEnabled()
        withBusy {
            let status = LoginItemControl.setEnabled(target)
            sender.state = status == .enabled ? .on : .off
        }
    }

    @objc func openDisplaysSettings(_ sender: Any?) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func quit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: — Helpers

    private func withBusy(_ work: () -> Void) {
        guard !busy else { return }
        busy = true
        work()   // mutations are sub-200ms subprocess calls; main thread is fine
        busy = false
        updateStatusIcon()
        // Rebuild after the current event unwinds (same pattern as the Python
        // app's delayedRefresh) so the control's own tracking loop is done.
        DispatchQueue.main.async { [weak self] in
            self?.rebuildPanelIfVisible()
        }
    }

    private func log(result: Result<OperationResult, some Error>, what: String) {
        switch result {
        case .success(let op):
            FileHandle.standardError.write(Data(
                "[RunClosed] \(what): state=\(op.state.rawValue) readback=\(op.readbackOK)\n".utf8))
        case .failure(let error):
            FileHandle.standardError.write(Data("[RunClosed] \(what): \(error)\n".utf8))
        }
    }
}
