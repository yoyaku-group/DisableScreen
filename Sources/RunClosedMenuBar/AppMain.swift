import AppKit
import UserNotifications
import RunClosedCore
import RunClosedMacSystem
import RunClosedPersistence
import RunClosedApp
import RunClosedHelperSupport

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
//   (B1), the automatic restore on quit requires ownership proven by readback
//   (B2), cross-boot record kept fail-closed (ADR 015). The popup switch is an
//   operator command and is honoured even without ownership (ADR 021).
// - Brightness targets ONE display (invariant 1): builtin → native
//   CoreDisplay write; external → software dim overlay floored at 0.08.
// - Reads are off-main (A09); the panel is rebuilt on main from cached state.
//
// - Low-battery guard (ADR 022): every 30 s, off-main, LowBatteryGuardService
//   evaluates battery + lid flag + ownership. Warn at 20%; at 10% (or ≤10 min
//   left inside the warn band) on battery it releases a flag WE own on this
//   boot through the same `.automatic` path (B1+B2) and runs `pmset sleepnow`
//   so `hibernatemode 3` preserves every process. Never acts on AC. A flag we
//   do not own is never mutated — the operator gets a loud notification.
//   Kill switch: `defaults write com.benjaminbelaga.RunClosed
//   lowBatteryGuardEnabled -bool false`.
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
    /// Last refused/failed lid toggle — cleared on the next success.
    private var lidError: String?

    /// Low-battery guard (ADR 022): timer + serial queue so two ticks never
    /// overlap, and the alert state that drives the status icon.
    private var guardTimer: Timer?
    private let guardQueue = DispatchQueue(label: "com.benjaminbelaga.RunClosed.lowBatteryGuard", qos: .utility)
    /// Held for the app's whole life: tells the CLI (and the L2 backstop) that
    /// something is enforcing session deadlines (ADR 023).
    private let appLiveness = AppLivenessLock()
    /// The liveness lock could not be taken (a second instance, or a CLI
    /// probe racing the launch): logged once, retried on every guard tick.
    private var livenessWarned = false
    /// `owned_lid.json` says the flag is ours on this boot. Read off the main
    /// thread with the 5 s lid poll, like `lidCache`.
    private var lidOwnedCache = false
    /// One store for the switch's writes: the canonical init creates the
    /// directory, which has no place on every main-thread action.
    private let sessionStore = SessionStore()
    /// `session.json` as last read off the main thread, with the 5 s lid poll
    /// (ADR 023). The title and the popup row read only this, never the
    /// file: they run on every icon refresh and popup rebuild.
    private var sessionCache: KeepAwakeSession?
    private var guardTickInFlight = false
    private var batteryAlert = false
    static let lowBatteryTickInterval: TimeInterval = 30

    /// Timed session (ADR 023). The countdown is refreshed once a minute —
    /// not on the 5 s lid poll and never in a busy loop.
    private var sessionTimer: Timer?
    /// Held while `disablesleep` is ours so App Nap does not stretch the guard
    /// timer with the lid closed (ADR 023 §5). Released as soon as the flag is
    /// no longer ours.
    private var keepAwakeActivity: NSObjectProtocol?
    static let sessionCountdownInterval: TimeInterval = 60

    // MARK: — Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureLivenessLock()
        registerBackstop()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // ADR 023 §5: a session's deadline may have passed while the machine
        // slept (that is the whole point of the continuous clock). Tick once on
        // wake so the flag does not stay on until the next 30 s timer.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Launch recovery: re-enable displays we owned, reconcile the lid
        // record (never auto-restore across boots — ADR 015).
        recoverAtLaunch()
        refreshLidCache()
        updateStatusIcon()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLidCache() }
        }
        startLowBatteryGuard()
        startSessionCountdown()
    }

    func applicationWillTerminate(_ notification: Notification) {
        var displayService = makeDisplayService()
        _ = displayService.restoreOwned()
        // Lid: restore ONLY if we own it on this boot (B2/ADR 015).
        // ADR 023 §5: the quit path is a lid writer like any other, so it takes
        // the same lock — a guard tick must not interleave with it.
        let bootID = clock.bootID
        let leftBehind = LidWriteLock().withLock { () -> KeepAwakeSession? in
            // Give up `app.lock` INSIDE this section: a CLI `session start`
            // queued behind the teardown must find the app gone once it gets
            // the lid lock. Otherwise the dying process still holds the flock
            // until exit, the CLI's liveness check passes, and a timed
            // session starts with nothing left to end it.
            self.appLiveness.release()
            var lidService = LidMutationService(
                bootID: bootID,
                mutator: LidAssertions.live(),
                store: OwnedLidAssertion(currentBootID: bootID),
                priorProvider: { PowerReadback.lidStayAwake() })
            _ = lidService.restoreIfOwned()
            // ADR 023: the session ends with the flag it was backing — a
            // record left behind would be a deadline nothing enforces. Go
            // through the SAME finish path as End and expiry, so the pending
            // low-battery re-arm is cleared too: a session paused by the
            // guard leaves the latch armed, and re-arming the flag on the
            // next launch on AC would resurrect a session that is gone.
            //
            // Only when a session exists: with no session on disk, quitting
            // must behave exactly as it did before this ADR (ADR 022's
            // re-arm debt survives a quit by design).
            return SessionService.live(bootID: bootID)
                .finishOnQuit(flagReadsOff: lidService.priorProvider() == false)
        }
        // The flag did not read off: the restore failed (`sudo -n`, a pmset
        // timeout) or the flag is not ours. The record stays, and with
        // `app.lock` gone nothing enforces it until RunClosed opens again.
        // Say so, outside the lid lock, before the process exits.
        if let left = leftBehind {
            FileHandle.standardError.write(Data(
                ("[RunClosed] quit: lid stay-awake did not read off; session \(left.id) "
                 + "ends=\(left.endsAtWall.map { ISO8601DateFormatter().string(from: $0) } ?? "indefinite") "
                 + "left on disk, not enforced until RunClosed reopens\n").utf8))
            if !left.isIndefinite {
                notify(L10n.t("RunClosed quit — Mac still awake"),
                       L10n.t("Lid stay-awake could not be turned off, so the session stays on with nothing to end it at its deadline. Reopen RunClosed, or turn it off with `runclosed-cli lid-stay-awake off --operator`."),
                       waitUpTo: 2)
            }
        }
    }

    /// A wake is a deadline check (ADR 023 §5). `mach_continuous_time` counted
    /// through the sleep, so a session that lapsed overnight is due the moment
    /// the machine comes back.
    @objc private func didWake() {
        Task { @MainActor in
            self.refreshLidCache()
            self.runLowBatteryTick()
            self.refreshSessionDisplay()
        }
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

    /// Register the ADR 024 recovery agent at launch when it is not registered
    /// yet. Idempotent by construction (`registerIfNeeded` never re-registers a
    /// pending or enabled service), and NEVER blocking: registration ends in
    /// `requiresApproval` on a fresh machine, which is a state to surface (the
    /// popup's backstop line + the Login Items deep link), not to fight.
    ///
    /// Off the main thread: `SMAppService` calls can take a moment and the menu
    /// bar must not stall on launch. A failure is logged, never swallowed into
    /// a phantom "enabled".
    private func registerBackstop() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // `automatic: true` — an app launch must never undo an explicit
            // `runclosed backstop unregister`.
            let report = BackstopLifecycleService(registrar: SMAppServiceAgentRegistrar())
                .registerIfNeeded(automatic: true)
            DispatchQueue.main.async {
                if report.lastOperationSucceeded == false {
                    FileHandle.standardError.write(Data(
                        "[RunClosed] backstop registration failed (status=\(report.status.rawValue))\n".utf8))
                } else if report.status == .requiresApproval {
                    FileHandle.standardError.write(Data(
                        "[RunClosed] backstop registered, waiting for approval in System Settings → Login Items\n".utf8))
                }
                self?.rebuildPanelIfVisible()
            }
        }
    }

    /// The backstop's state for the popup (ADR 024). Read on the main thread:
    /// `SMAppService.status` is a cheap, in-process dictionary lookup (it is
    /// the same call the login-item row already makes on every rebuild).
    ///
    /// It applies the SAME rule as the CLI: registration (`enabled`) is not
    /// enough, the agent must also have proven it RUNS (a fresh, successful
    /// heartbeat on this boot). Showing nothing on `enabled` alone would tell
    /// the operator the Mac is protected while they quit the app, in exactly
    /// the case the heartbeat exists to catch — an approved agent whose program
    /// never resolves.
    private func backstopRow() -> PopupState.BackstopRow {
        let report = BackstopLifecycleService(registrar: SMAppServiceAgentRegistrar()).report()
        let status = report.status
        if status.isProtecting {
            let freshness = RecoveryPolicy.runFreshnessFull(
                heartbeat: BackstopHeartbeatStore().freshnessInput(),
                currentBootID: clock.bootID,
                now: Date())
            guard !freshness.isEnforcing else {
                // The net is genuinely up: the popup stays quiet.
                return PopupState.BackstopRow(status: status.rawValue, summary: nil,
                                             needsApproval: false)
            }
            // Registered and approved, but not provably running.
            return PopupState.BackstopRow(
                status: status.rawValue,
                summary: L10n.t("Recovery backstop enabled but not running (see log)"),
                needsApproval: false)
        }
        return PopupState.BackstopRow(
            status: status.rawValue,
            summary: status == .requiresApproval
                ? L10n.t("Recovery backstop off — approve it in System Settings")
                : L10n.t("Recovery backstop off (see log)"),
            needsApproval: status == .requiresApproval)
    }

    /// Open System Settings → Login Items so the operator can approve the
    /// `requiresApproval` backstop agent. Performs no privileged work.
    @objc func openBackstopApproval(_ sender: Any?) {
        BackstopLifecycleService(registrar: SMAppServiceAgentRegistrar()).openApprovalSettings()
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

    /// Every action that may change the flag or the session calls this, so a
    /// Start, +30 min or End (or a CLI change) redraws as soon as the
    /// background read lands.
    private func refreshLidCache() {
        let bootID = clock.bootID
        let sessionURL = sessionStore.url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = PowerReadback.lidStayAwake()
            let rec = OwnedLidAssertion(currentBootID: bootID).load()
            let owned = rec.ownedEnabled && rec.bootID == bootID
            let session = SessionStore(url: sessionURL).load()
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.lidCache != value
                let sessionChanged = self.sessionCache != session
                self.lidCache = .some(value)
                self.lidOwnedCache = owned
                self.sessionCache = session
                self.lidReady = true
                self.syncKeepAwakeActivity()
                if sessionChanged { self.updateStatusTitle() }
                if changed || sessionChanged { self.rebuildPanelIfVisible() }
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
        var symbol = disabledCount > 0 ? "display.slash" : "laptopcomputer"
        // Low battery with lid stay-awake ON: make it visible in the bar.
        if batteryAlert, NSImage(systemSymbolName: "battery.25percent", accessibilityDescription: nil) != nil {
            symbol = "battery.25percent"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusItem.button?.image?.isTemplate = true
        updateStatusTitle()
        syncKeepAwakeActivity()
    }

    /// Remaining time next to the icon (ADR 023 §6). Empty for an indefinite
    /// session — the plain switch stays exactly as it was.
    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let now = SystemContinuousClock(bootID: clock.bootID)
        let session = sessionCache
        let policyNow = SessionPolicy.Now(
            wall: Date(),
            continuousNanoseconds: now.nowContinuousNanoseconds,
            bootID: clock.bootID)
        if let session, !session.isIndefinite,
           let label = SessionPolicy.compactRemainingLabel(session, now: policyNow) {
            // "2h41" — the bar has no room for words.
            button.title = (session.pausedReason != nil ? " ⏸ " : " ") + label
        } else {
            button.title = ""
        }
    }

    /// Refresh everything that shows the countdown, off the 30 s guard cadence.
    private func refreshSessionDisplay() {
        updateStatusTitle()
        rebuildPanelIfVisible()
    }

    private func startSessionCountdown() {
        // Once a minute is enough: the label's finest unit is minutes.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: Self.sessionCountdownInterval,
                                            repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessionDisplay() }
        }
    }

    /// Hold `beginActivity` while a TIMED session runs on a flag that is ours,
    /// so App Nap cannot stretch the timer that enforces its deadline with
    /// the lid closed (ADR 023). The activity opts out of App Nap only: it
    /// never keeps the Mac awake by itself (`AllowingIdleSystemSleep`), so an
    /// OFF set by someone else takes effect at once even before the next 5 s
    /// readback ends it. The plain switch (indefinite session) and a paused
    /// session hold nothing, as before this ADR (ADR 022 unchanged).
    private func syncKeepAwakeActivity() {
        // The cached readback, ownership and session (refreshed off the main
        // thread every 5 s), never a fresh `pmset -g` or file read here: this
        // runs on every icon refresh.
        let observed: Bool? = lidCache ?? nil
        let timedSessionRuns = sessionCache.map { !$0.isIndefinite && !$0.isPaused } ?? false
        let ours = timedSessionRuns && lidOwnedCache && observed == true
        if ours, keepAwakeActivity == nil {
            keepAwakeActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "RunClosed timed keep-awake session")
        } else if !ours, let activity = keepAwakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            keepAwakeActivity = nil
        }
    }

    /// `"2 h 41 left"` through the localization table, so French reads
    /// "2 h 41 restantes". The arithmetic lives in `SessionPolicy` (pure,
    /// tested); only the words are localized here.
    private static func localizedRemaining(_ session: KeepAwakeSession, now: SessionPolicy.Now) -> String {
        guard let seconds = SessionPolicy.remaining(session, now: now) else { return "" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 0 { return L10n.t("< 1 min left") }
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return L10n.t("%@ min left", String(m)) }
        if m == 0 { return L10n.t("%@ h left", String(h)) }
        return L10n.t("%@ h %@ left", String(h), String(m))
    }

    /// Is `disablesleep` ours on THIS boot? Read from the ownership record
    /// (the same source `LidMutationService` gates on) and confirmed by the
    /// live readback: a stale record with the flag observed OFF is not ours.
    private func showContextMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: L10n.t("Refresh"), action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.t("Open macOS Display Settings"), action: #selector(openDisplaysSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.t("Quit RunClosed"), action: #selector(quit(_:)), keyEquivalent: "q")
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
                ? L10n.t("Built-in Display")
                : (snap?.identity.localizedName ?? L10n.t("Display %@", String(id)))
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
            : L10n.t("Active sessions (%@): %@", String(leases.count), leases.map(\.owner).joined(separator: ", "))

        return PopupState(
            displays: cards,
            lid: lidState,
            lidCanToggle: lidValue != nil,
            lidPending: false,
            lidError: lidError,
            loginItemEnabled: LoginItemControl.isEnabled(),
            loginItemAvailable: LoginItemControl.isActionable(),
            leasesSummary: summary,
            busy: busy,
            session: sessionRow(),
            backstop: backstopRow()
        )
    }

    /// What the lid row should say about the session (ADR 023 §6). Reads the
    /// cached record and the clocks only: no file read, no mutation.
    private func sessionRow() -> PopupState.SessionRow {
        let clock = SystemContinuousClock(bootID: self.clock.bootID)
        let now = SessionPolicy.Now(
            wall: Date(),
            continuousNanoseconds: clock.nowContinuousNanoseconds,
            bootID: self.clock.bootID)
        guard let session = sessionCache else {
            return PopupState.SessionRow(label: nil, timed: false, indefinite: false,
                                         pausedReason: nil, due: false)
        }
        let due = SessionPolicy.isDue(session, now: now)
        // All user-visible text goes through L10n (English key + FR table);
        // `SessionPolicy` keeps an English rendering only for the CLI, where a
        // script reads it.
        let label: String?
        if session.isIndefinite {
            label = L10n.t("Indefinite — switch it off to end it")
        } else if let ends = session.endsAtWall {
            let formatter = DateFormatter()
            // A session can last up to 7 days: past today, name the day too,
            // or "Until 14:30" on Sunday would read as today for a Tuesday end.
            formatter.setLocalizedDateFormatFromTemplate(
                Calendar.current.isDateInToday(ends) ? "HH:mm" : "EEE HH:mm")
            let until = formatter.string(from: ends)
            if session.pausedReason == .lowBattery {
                // The guard released the flag: say so, the Mac can sleep now.
                label = L10n.t("Paused (low battery) · until %@", until)
            } else if session.pausedReason != nil {
                label = L10n.t("Paused · until %@", until)
            } else {
                label = L10n.t("Until %@ · %@", until, Self.localizedRemaining(session, now: now))
            }
        } else {
            label = Self.localizedRemaining(session, now: now)
        }
        return PopupState.SessionRow(
            label: label,
            timed: !session.isIndefinite,
            indefinite: session.isIndefinite,
            pausedReason: session.pausedReason?.rawValue,
            due: due)
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
            // The click IS the operator's decision (ADR 021): a stale
            // cross-boot record or a flag set by another tool must not
            // leave the switch stuck ON.
            // Same lock as the low-battery guard tick (ADR 022): the click
            // waits for a guard mutation in flight instead of racing it, and
            // its latch clear cannot be overwritten by a stale tick save.
            // Non-blocking on main: if a guard tick (or the CLI) holds the
            // lock, say "busy" instead of freezing the menu bar.
            let sessionStore = self.sessionStore
            guard let result = LidWriteLock().tryWithLock({ () -> Result<OperationResult, LidMutationError> in
                let r = service.setEnabled(target, initiator: .operatorCommand)
                // The operator's explicit choice supersedes a pending
                // low-battery re-arm.
                LowBatteryLatchStore().operatorCommandFinished(r)
                // ADR 023: the plain switch IS an indefinite session. Turning
                // it OFF ends that session (and any timed one the switch was
                // backing); turning it ON records an indefinite session so
                // every surface reports one shape, except that a live timed
                // session (e.g. paused by the battery guard) resumes with its
                // deadline instead of losing it.
                let switchedOn: () -> Void = {
                    let now = SessionPolicy.Now(
                        wall: Date(),
                        continuousNanoseconds: SystemContinuousClock(bootID: self.clock.bootID)
                            .nowContinuousNanoseconds,
                        bootID: self.clock.bootID)
                    sessionStore.save(SessionPolicy.recordAfterSwitchOn(
                        existing: sessionStore.load(), now: now))
                }
                switch r {
                case .success(let op) where target && op.state == .verified:
                    switchedOn()
                case .success(let op) where target:
                    // The write reported success but its readback did not
                    // confirm the flag ON (`pending`/`unknown`/`conflict`): for
                    // the session record this is a FAILURE, like the `.failure`
                    // branch below. Recording an indefinite session here would
                    // put a deadline-less "running session" on every surface
                    // for a flag that is not observed ON — and the record is
                    // what `status`, the popup and the log read.
                    FileHandle.standardError.write(Data(
                        "[RunClosed] lid -> on: state=\(op.state.rawValue) readback not verified; no session recorded\n".utf8))
                case .success:
                    sessionStore.clear()
                case .failure(.noChangeRequested(let requested)) where requested:
                    switchedOn()
                case .failure(.noChangeRequested):
                    sessionStore.clear()
                case .failure:
                    break
                }
                return r
            }) else {
                self.lidError = L10n.t("Busy, try again")
                self.refreshLidCache()
                return
            }
            self.log(result: result, what: "lid -> \(target)")
            self.lidError = Self.lidFailureHint(result)
            self.refreshLidCache()
        }
    }

    // MARK: — Session actions (ADR 023)

    /// One of the 1 h / 2 h / 4 h / 8 h buttons. The duration travels in the
    /// button tag, in seconds.
    @objc func startSession(_ sender: NSButton) {
        let duration = TimeInterval(sender.tag)
        guard duration > 0 else { return }
        withBusy {
            var service = self.makeSessionService()
            // Non-blocking on main: never freeze the menu bar behind a guard
            // tick. The service itself never takes the lock (that would nest).
            guard let result = LidWriteLock().tryWithLock({ service.start(for: duration) }) else {
                self.lidError = L10n.t("Busy, try again")
                return
            }
            switch result {
            case .success(let outcome):
                self.lidError = nil
                FileHandle.standardError.write(Data(
                    "[RunClosed] session start: \(outcome)\n".utf8))
            case .failure(let error):
                self.lidError = Self.sessionFailureHint(error)
                self.logSession(.failure(error))
            }
            self.refreshLidCache()
            // The flag may not change (adoption, +30 min): redraw the countdown now.
            self.refreshSessionDisplay()
        }
    }

    @objc func extendSession(_ sender: Any?) {
        withBusy {
            var service = self.makeSessionService()
            guard let result = LidWriteLock().tryWithLock({ service.extend() }) else {
                self.lidError = L10n.t("Busy, try again")
                return
            }
            switch result {
            case .success:
                self.lidError = nil
            case .failure(let error):
                self.lidError = Self.sessionFailureHint(error)
            }
            if case .failure(let error) = result { self.logSession(.failure(error)) }
            self.refreshLidCache()
            self.refreshSessionDisplay()
        }
    }

    @objc func endSession(_ sender: Any?) {
        withBusy {
            var service = self.makeSessionService()
            // The click IS the operator (ADR 021).
            guard let result = LidWriteLock().tryWithLock({ service.end(byOperator: true) }) else {
                self.lidError = L10n.t("Busy, try again")
                return
            }
            switch result {
            case .success(.flagLeftOn):
                // The session is gone, but the flag it ran on is not
                // provably ours, so End did not turn it off (B2).
                self.lidError = L10n.t("Session ended, but lid stay-awake is still on (not set by RunClosed) — use the switch to turn it off")
            case .success(let outcome) where !outcome.isFailure:
                self.lidError = nil
            case .success(let outcome):
                self.lidError = L10n.t("Change failed (see log)")
                FileHandle.standardError.write(Data(
                    "[RunClosed] session end: \(outcome.rawValue) \(outcome.failureMessage ?? "-")\n".utf8))
            case .failure(let error):
                self.lidError = Self.sessionFailureHint(error)
                self.logSession(.failure(error))
            }
            self.refreshLidCache()
            self.refreshSessionDisplay()
        }
    }

    private func logSession(_ result: Result<KeepAwakeSession, SessionError>) {
        switch result {
        case .success(let s):
            FileHandle.standardError.write(Data(
                "[RunClosed] session: id=\(s.id) ends=\(s.endsAtWall.map { ISO8601DateFormatter().string(from: $0) } ?? "indefinite")\n".utf8))
        case .failure(let e):
            FileHandle.standardError.write(Data("[RunClosed] session: refused \(e)\n".utf8))
        }
    }

    private static func sessionFailureHint(_ error: SessionError) -> String {
        switch error {
        case .flagOnNotOwned:
            return L10n.t("Lid stay-awake is on but not owned by RunClosed — switch it off then on first")
        case .alreadyRunning:
            return L10n.t("A session is already running")
        case .noSession:
            return L10n.t("No session is running")
        case .indefiniteSession:
            return L10n.t("This session has no end time")
        case .durationTooLong:
            return L10n.t("That is longer than 7 days")
        case .nonPositiveDuration:
            return L10n.t("Change failed (see log)")
        case .preconditionUnknown:
            return L10n.t("unknown state")
        case .notOwned, .flagAlreadyOff, .backendFailed:
            return L10n.t("Change failed (see log)")
        }
    }

    private func makeSessionService() -> SessionService {
        SessionService.live(bootID: clock.bootID)
    }

    private static func lidFailureHint(_ result: Result<OperationResult, LidMutationError>) -> String? {
        switch result {
        case .success:
            return nil
        case .failure(.noChangeRequested):
            return nil   // stale cache: the refresh re-renders the real state
        case .failure(.preconditionUnknown):
            return L10n.t("unknown state")
        case .failure(.notOwned), .failure(.backendFailed):
            return L10n.t("Change failed (see log)")
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

    // MARK: — Low-battery guard (ADR 022)

    private func startLowBatteryGuard() {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        // First tick shortly after launch (a Mac that boots on a low battery
        // must not wait a full interval), then every 30 s.
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.runLowBatteryTick() }
        }
        guardTimer = Timer.scheduledTimer(withTimeInterval: Self.lowBatteryTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runLowBatteryTick() }
        }
    }

    /// Take `app.lock` if this process does not hold it yet. A failure (a
    /// second RunClosed instance, or a CLI probe that held the file at the
    /// very moment of the launch) is logged once and retried on every tick:
    /// until it succeeds, `session start --for` refuses, which is the safe
    /// side.
    private func ensureLivenessLock() {
        if appLiveness.hold() {
            livenessWarned = false
            return
        }
        guard !livenessWarned else { return }
        livenessWarned = true
        FileHandle.standardError.write(Data(
            "[RunClosed] app.lock is held by another process; retrying on every guard tick (timed sessions from the CLI are refused until then)\n".utf8))
    }

    private func runLowBatteryTick() {
        ensureLivenessLock()
        guard LowBatteryGuardSettings.isEnabled() else {
            if batteryAlert { batteryAlert = false; updateStatusIcon() }
            // The battery kill switch must not switch deadlines off with it.
            runSessionOnlyTick()
            return
        }
        // Never race an operator toggle on the same flag/record.
        guard !busy, !guardTickInFlight else { return }
        guardTickInFlight = true
        let bootID = clock.bootID
        guardQueue.async { [weak self, bootID] in
            var service = LowBatteryGuardService(
                lidService: LidMutationService(
                    bootID: bootID,
                    mutator: LidAssertions.live(),
                    store: OwnedLidAssertion(currentBootID: bootID),
                    priorProvider: { PowerReadback.lidStayAwake() }),
                latchStore: LowBatteryLatchStore(),
                batteryProvider: { BatteryReadback.read() },
                sleeper: PMSetSleeper(),
                // ADR 023: the SAME tick (one LidWriteLock section) expires a
                // due session and pauses/resumes it around a battery release.
                sessionService: SessionService.live(bootID: bootID))
            let outcome = service.tick()
            DispatchQueue.main.async {
                self?.handleLowBattery(outcome)
            }
        }
    }

    /// The session step alone (ADR 023), for when the low-battery guard is
    /// switched off: same queue, same single `LidWriteLock` section, so a
    /// deadline still ends on time with the battery guard disabled.
    private func runSessionOnlyTick() {
        guard !busy, !guardTickInFlight else { return }
        guardTickInFlight = true
        let bootID = clock.bootID
        guardQueue.async { [weak self, bootID] in
            var service = SessionService.live(bootID: bootID)
            let step = LidWriteLock().withLock { service.step() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.guardTickInFlight = false
                self.handleSessionStep(expiry: step.expiry, reconciled: step.reconciled)
            }
        }
    }

    /// What every tick does with the session step's result, with or without
    /// the battery guard.
    private func handleSessionStep(expiry: SessionService.ExpiryOutcome?,
                                   reconciled: SessionService.ReconcileOutcome?) {
        var changed = false
        if let expiry, expiry != .noSession, expiry != .notDue {
            FileHandle.standardError.write(Data(
                "[RunClosed] session tick: \(String(describing: expiry))\n".utf8))
            changed = true
        }
        if let reconciled {
            FileHandle.standardError.write(Data(
                "[RunClosed] session reconciled (flag reads off): \(String(describing: reconciled))\n".utf8))
            changed = true
        }
        if changed {
            refreshLidCache()
            refreshSessionDisplay()
        }
        guard case .ended(let end)? = expiry else { return }
        if end.stopsKeepingAwake {
            notify(L10n.t("Session ended"),
                   L10n.t("The keep-awake session reached its end time and lid stay-awake was turned off."))
        } else if end == .flagLeftOn {
            // Never a quiet "Session ended": the Mac is still awake, with no
            // deadline and no RunClosed owner (ADR 023).
            notify(L10n.t("Session ended — Mac still awake"),
                   L10n.t("The keep-awake session reached its end time, but lid stay-awake is still on and RunClosed did not set it, so it was left on. Turn it off with the switch in RunClosed."))
        }
    }

    private func handleLowBattery(_ outcome: LowBatteryGuardService.TickOutcome) {
        guardTickInFlight = false
        let e = outcome.evaluation
        let pct = e.input.chargePercent.map(String.init) ?? "?"

        // ADR 023: the session step ran first inside the same lock section.
        handleSessionStep(expiry: outcome.session, reconciled: outcome.sessionReconciled)

        let alert = (e.decision.level == .low || e.decision.level == .critical)
            && e.input.lidFlag != false
        if alert != batteryAlert {
            batteryAlert = alert
            updateStatusIcon()
        }
        if e.decision.action != .none || outcome.mutation != nil {
            FileHandle.standardError.write(Data(
                ("[RunClosed] low-battery: level=\(e.decision.level.rawValue) action=\(e.decision.action.rawValue) "
                 + "reason=\(e.decision.reason.rawValue) pct=\(pct) min=\(e.input.minutesRemaining.map(String.init) ?? "?") "
                 + "ownership=\(e.input.ownership.rawValue) mutation=\(outcome.mutation?.rawValue ?? "-") "
                 + "error=\(outcome.mutationError ?? "-") sleep=\(outcome.sleepAttempted ? String(outcome.sleepRC ?? -1) : "-")\n").utf8))
        }

        if let mutation = outcome.mutation {
            if outcome.mutation == .released || outcome.mutation == .rearmed {
                refreshLidCache()
            }
            if outcome.sessionResumed { refreshLidCache() }
            // Failures notify once per discharge episode (service latch).
            guard outcome.shouldNotify else { return }
            switch mutation {
            case .released where e.decision.reason == .emergencyStaleOwnership:
                notify(L10n.t("Battery critical: emergency sleep"),
                       L10n.t("%@%% on battery: lid stay-awake was still on from before the last restart. RunClosed turned it off as an emergency and the Mac is going to sleep (hibernation keeps every process). It comes back on once charging above 15%%.", pct))
            case .released:
                notify(L10n.t("Battery critical: sleeping now"),
                       L10n.t("%@%% on battery: lid stay-awake turned off and the Mac is going to sleep. It comes back on once charging above 15%%.", pct))
            case .releaseFailed:
                notify(L10n.t("Battery critical: plug in now"),
                       L10n.t("%@%% on battery and lid stay-awake could not be turned off (%@). Sleep was attempted anyway.", pct, outcome.mutationError ?? "-"))
            case .releaseRefused:
                notify(L10n.t("Battery critical: plug in now"),
                       L10n.t("%@%% on battery. The low-battery guard was refused (%@) and the Mac will not sleep by itself.", pct, outcome.mutationError ?? "-"))
            case .rearmed:
                notify(L10n.t("Lid stay-awake restored"),
                       L10n.t("Back on power above 15%: keep awake with lid closed is on again."))
            case .rearmAlreadyOn, .rearmFailed:
                break   // logged above; retried on the next tick
            }
            return
        }

        guard e.decision.action == .warn else { return }
        switch e.decision.reason {
        case .lowBatteryUnprotected:
            notify(L10n.t("Battery low: lid stay-awake is NOT protected"),
                   L10n.t("%@%% on battery. Lid stay-awake is on but was turned on by another tool (or its state cannot be read), so RunClosed will NOT turn it off at 10%% and the Mac will not sleep by itself. Plug in, or switch \"Keep awake with lid closed\" off then on so RunClosed owns it.", pct))
        case .lowBattery:
            notify(L10n.t("Battery low: lid stay-awake is on"),
                   L10n.t("%@%% on battery. At 10%%, RunClosed turns lid stay-awake off and puts the Mac to sleep (hibernation keeps every process). Plug in to avoid it.", pct))
        case .criticalNotOwned:
            notify(L10n.t("Battery critical: plug in now"),
                   L10n.t("%@%% on battery. Lid stay-awake was turned on by another tool, so RunClosed will not turn it off. Plug in, or turn it off yourself.", pct))
        case .lidFlagUnknown:
            notify(L10n.t("Battery critical: plug in now"),
                   L10n.t("%@%% on battery and the lid stay-awake state cannot be read. Plug in now.", pct))
        default:
            break
        }
    }

    /// User notification, with a stderr trace. Unbundled dev runs (no bundle
    /// identifier) cannot use UNUserNotificationCenter — beep instead.
    /// `waitUpTo`: block up to that many seconds until the request reaches
    /// the notification center — for the quit teardown, where the process
    /// exits right after. The completion runs off the main thread, so the
    /// wait cannot deadlock.
    private func notify(_ title: String, _ body: String, waitUpTo timeout: TimeInterval? = nil) {
        FileHandle.standardError.write(Data("[RunClosed] notify: \(title) — \(body)\n".utf8))
        guard Bundle.main.bundleIdentifier != nil else {
            NSSound.beep()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "runclosed.low-battery.\(UUID().uuidString)",
            content: content, trigger: nil)
        guard let timeout else {
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            return
        }
        let sent = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { _ in sent.signal() }
        _ = sent.wait(timeout: .now() + timeout)
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
