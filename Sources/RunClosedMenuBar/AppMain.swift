import AppKit
import RunClosedCore
import RunClosedMacSystem
import RunClosedApp

// G2a — menu-bar app, READ-ONLY.
//
// Gating rationale (backlog G2 suite):
// - This tranche ships a faithful VIEW of the same state the Python app shows.
// - It MUTATES NOTHING — no `SLSConfigureDisplayEnabled`, no `pmset disablesleep`.
// - The mutation toggles are present in the menu but disabled with a tooltip
//   pointing at G2b/G2c. Visible-but-disabled is honest (not silently absent):
//   the user sees the affordance and knows it's a planned addition.
//
// Refresh strategy:
// - Notification-based for display changes (coalesced via a 0.5s timer — A19).
// - 5s timer for the rest (lidStayAwake + leases).
// - All reads happen off-main; menu mutation on main. A09 discipline.
//
// Bootid sourcing:
// - We read /usr/bin/sysctl -n kern.bootsessionuuid at app start. If absent
//   (rare, e.g. headless), fall back to "unknown" — leases from any other
//   boot are filtered, so a wrong boot just hides them.

@main
struct RunClosedMenuBarApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // LSUIElement equivalent at runtime
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var screensTimer: Timer?
    private var lastSnapshot: SnapshotViewModel?

    // Lightweight boot-ID read. Returns "unknown" on failure so filtering still
    // works (just hides more leases than necessary — safe-by-default).
    private let bootID: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sysctl")
        p.arguments = ["-n", "kern.bootsessionuuid"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "unknown" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "unknown" : s
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "○"   // honest glyph — no claim of state we don't have

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        refreshNow()
        // Conservative cadence: 5s. The snapshots are cheap; coalescing is for
        // user sanity, not CPU. Timer callbacks are nonisolated — hop to main.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    @objc private func screensChanged() {
        // Coalesce (A19): a topology change can fire several notifications in
        // quick succession; collapse them into one refresh.
        screensTimer?.invalidate()
        screensTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    private func refreshNow() {
        // Read off-main, then update the menu on main.
        let boot = self.bootID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshots = DisplayInventory.snapshot()
            let lid = PowerReadback.lidStayAwake()
            let engine = LeaseReader.load(clock: SystemClock(bootID: boot))
            let vm = SnapshotBuilder.make(now: Date(), snapshots: snapshots,
                                          lidStayAwake: lid,
                                          leases: engine.leases,
                                          currentBootID: boot)
            DispatchQueue.main.async { self?.apply(vm: vm) }
        }
    }

    private func apply(vm: SnapshotViewModel) {
        self.lastSnapshot = vm
        statusItem.menu = buildMenu(from: vm)
        // Update the title glyph: ● if a display is non-native-capable, ○ otherwise.
        // We don't claim "online" because that's a mutation-adjacent claim; honest
        // default is "○" with the menu as the source of truth.
    }

    private func buildMenu(from vm: SnapshotViewModel) -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "RunClosed", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Lid stay-awake
        let lidItem = NSMenuItem(title: lidLabel(vm.lidStayAwake), action: nil,
                                 keyEquivalent: "")
        lidItem.isEnabled = false
        menu.addItem(lidItem)

        // Lid toggle (disabled — G2c)
        let lidToggle = NSMenuItem(title: "  ↳ Capot (bascule)",
                                   action: #selector(toggleLidClicked),
                                   keyEquivalent: "")
        lidToggle.target = self
        lidToggle.toolTip = "Mutation désactivée en G2a — livrée en G2c (pmset disablesleep)"
        lidToggle.isEnabled = false
        menu.addItem(lidToggle)
        menu.addItem(.separator())

        // Displays
        let dispHeader = NSMenuItem(title: "Écrans (\(vm.displays.count))",
                                    action: nil, keyEquivalent: "")
        dispHeader.isEnabled = false
        menu.addItem(dispHeader)
        if vm.displays.isEmpty {
            let none = NSMenuItem(title: "  (aucun)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for d in vm.displays {
            let label = "  \(d.label) — \(d.brightnessLabel) — \(d.mode)"
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        // Display toggle (disabled — G2b)
        let dispToggle = NSMenuItem(title: "  ↳ Activer/Désactiver un écran",
                                    action: #selector(toggleDisplayClicked),
                                    keyEquivalent: "")
        dispToggle.target = self
        dispToggle.toolTip = "Mutation désactivée en G2a — livrée en G2b (SLSConfigureDisplayEnabled)"
        dispToggle.isEnabled = false
        menu.addItem(dispToggle)
        menu.addItem(.separator())

        // Leases
        let lh = NSMenuItem(title: "Sessions actives (\(vm.leases.count))",
                            action: nil, keyEquivalent: "")
        lh.isEnabled = false
        menu.addItem(lh)
        if vm.leases.isEmpty {
            let none = NSMenuItem(title: "  (aucune)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for l in vm.leases {
            let line = "  \(l.owner) — \(l.workSource) — \(l.state)"
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Actions
        let refresh = NSMenuItem(title: "Rafraîchir", action: #selector(refreshClicked),
                                 keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        // Standard mac system settings
        let settings = NSMenuItem(title: "Réglages Écran macOS",
                                  action: #selector(openDisplaysSettings),
                                  keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quitter RunClosed",
                              action: #selector(quitClicked),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func lidLabel(_ s: SnapshotViewModel.PowerState) -> String {
        switch s {
        case .on:    return "Capot · désactivation sommeil : activée"
        case .off:   return "Capot · désactivation sommeil : désactivée"
        case .unknown: return "Capot · désactivation sommeil : état inconnu (pmset illisible)"
        }
    }

    @objc private func refreshClicked() { refreshNow() }

    @objc private func openDisplaysSettings() {
        // macOS 14+ canonical settings URL for displays
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleDisplayClicked() {
        NSSound.beep()   // Honest signal: clicked but not wired in this tranche.
    }

    @objc private func toggleLidClicked() {
        NSSound.beep()
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
