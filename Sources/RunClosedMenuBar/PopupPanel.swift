import AppKit
import RunClosedCore
import RunClosedApp

/// The toggle popup — borderless NSPanel anchored under the status item,
/// visually a popover (vibrancy + rounded corners). Geometry is a faithful
/// port of the Python DisableScreen panel (PANEL_W 280, 46/36/34/34 row
/// heights) so the muscle memory from the old app carries over.
///
/// The panel only RENDERS: every control carries a tag (display id) and
/// targets the delegate's @objc actions. State assembly lives in the
/// delegate; this file has no mutation logic.
final class PopupPanel: NSPanel {

    static let width: CGFloat = 280
    static let cornerRadius: CGFloat = 12

    private static let hHeader: CGFloat = 46
    private static let hExternalButton: CGFloat = 36
    private static let hBrightness: CGFloat = 34
    private static let hResolution: CGFloat = 34
    private static let hSeparator: CGFloat = 1
    private static let hQuit: CGFloat = 36
    private static let hLid: CGFloat = 36
    private static let hLogin: CGFloat = 36
    private static let hLeases: CGFloat = 26
    private static let pad: CGFloat = 8

    var onDismiss: (() -> Void)?

    static func create() -> PopupPanel {
        let p = PopupPanel(
            contentRect: NSMakeRect(0, 0, width, 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        return p
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onDismiss?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: — Content assembly

    /// Build the whole content view for a state snapshot. Returns the view and
    /// its height; the caller sizes/positions the panel.
    static func buildContent(_ state: PopupState, target: AnyObject) -> (NSView, CGFloat) {
        var total = pad
        total += hQuit + hSeparator
        total += hLogin + hSeparator
        total += hLid + hSeparator
        total += hLeases + hSeparator
        for card in state.displays {
            total += cardHeight(card)
        }
        if state.displays.count > 1 {
            total += CGFloat(state.displays.count - 1) * (hSeparator + 4)
        }
        total += pad

        let root = NSView(frame: NSMakeRect(0, 0, width, total))
        var y = pad

        // — Quit (bottom-most)
        let quit = NSButton(frame: NSMakeRect(14, y + 6, width - 28, 24))
        quit.title = L10n.t("Quit RunClosed")
        quit.bezelStyle = .rounded
        quit.font = .systemFont(ofSize: 13)
        quit.target = target
        quit.action = #selector(AppDelegate.quit(_:))
        root.addSubview(quit)
        y += hQuit

        root.addSubview(separator(at: y))
        y += hSeparator

        // — Login item
        let (loginRow, loginH) = loginRow(state, target: target)
        loginRow.frame = NSMakeRect(0, y, width, loginH)
        root.addSubview(loginRow)
        y += hLogin

        root.addSubview(separator(at: y))
        y += hSeparator

        // — Lid stay-awake
        let (lidRow, _) = lidRow(state, target: target)
        lidRow.frame = NSMakeRect(0, y, width, hLid)
        root.addSubview(lidRow)
        y += hLid

        root.addSubview(separator(at: y))
        y += hSeparator

        // — Leases summary (read-only CLI view)
        let leases = NSTextField(labelWithString: state.leasesSummary ?? L10n.t("Active sessions: none"))
        leases.frame = NSMakeRect(14, y + 6, width - 28, 14)
        leases.font = .systemFont(ofSize: 11)
        leases.textColor = .secondaryLabelColor
        leases.lineBreakMode = .byTruncatingTail
        root.addSubview(leases)
        y += hLeases

        root.addSubview(separator(at: y))
        y += hSeparator + 4

        // — Display cards (top-down: built-in first, same order as the model)
        for (i, card) in state.displays.enumerated() {
            let cardView = displayCard(card, state: state, target: target)
            let h = cardHeight(card)
            cardView.frame = NSMakeRect(0, y, width, h)
            root.addSubview(cardView)
            y += h
            if i < state.displays.count - 1 {
                root.addSubview(separator(at: y))
                y += hSeparator + 4
            }
        }

        // — Vibrancy backdrop
        let fx = NSVisualEffectView(frame: NSMakeRect(0, 0, width, total))
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        fx.addSubview(root)
        return (fx, total)
    }

    static func cardHeight(_ card: PopupState.DisplayCard) -> CGFloat {
        if card.isDisabled { return hHeader }
        var h = hHeader
        if !card.builtin { h += hExternalButton }
        if card.brightness != nil { h += hBrightness }
        h += hResolution
        return h
    }

    // MARK: — Rows

    private static func displayCard(_ card: PopupState.DisplayCard,
                                    state: PopupState,
                                    target: AnyObject) -> NSView {
        let h = cardHeight(card)
        let view = NSView(frame: NSMakeRect(0, 0, width, h))
        var y = h - hHeader

        let icon = NSImageView(frame: NSMakeRect(14, y + 14, 18, 18))
        icon.image = NSImage(systemSymbolName: card.builtin ? "laptopcomputer" : "display",
                             accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        if card.isDisabled { icon.alphaValue = 0.35 }
        view.addSubview(icon)

        let name = NSTextField(labelWithString: card.ambiguous ? "\(card.name) ⚠︎" : card.name)
        name.frame = NSMakeRect(40, y + 17, width - 100, 15)
        name.font = .boldSystemFont(ofSize: 13)
        if card.isDisabled { name.textColor = .tertiaryLabelColor }
        view.addSubview(name)

        if !card.isDisabled, card.resolution != "-" {
            let res = NSTextField(labelWithString: card.resolution)
            res.frame = NSMakeRect(40, y + 4, 120, 11)
            res.font = .systemFont(ofSize: 10)
            res.textColor = .secondaryLabelColor
            view.addSubview(res)
        }

        let sw = NSSwitch(frame: NSMakeRect(width - 54, y + 12, 44, 22))
        sw.state = card.isDisabled ? .off : .on
        sw.tag = Int(card.id)
        sw.target = target
        sw.action = #selector(AppDelegate.toggleDisplay(_:))
        sw.isEnabled = card.canToggle && !state.busy
        view.addSubview(sw)

        if card.isDisabled { return view }

        if !card.builtin {
            y -= hExternalButton
            let btn = NSButton(frame: NSMakeRect(14, y + 6, width - 28, 24))
            btn.title = L10n.t("Open macOS Display Settings…")
            btn.bezelStyle = .rounded
            btn.font = .systemFont(ofSize: 11)
            btn.target = target
            btn.action = #selector(AppDelegate.openDisplaysSettings(_:))
            btn.contentTintColor = .systemBlue
            view.addSubview(btn)
        }

        if let bri = card.brightness {
            y -= hBrightness
            let sun = NSImageView(frame: NSMakeRect(14, y + 10, 14, 14))
            sun.image = NSImage(systemSymbolName: "sun.min", accessibilityDescription: nil)
            sun.imageScaling = .scaleProportionallyDown
            view.addSubview(sun)

            let pct = NSTextField(labelWithString: "\(Int(bri * 100))%")
            pct.frame = NSMakeRect(width - 44, y + 11, 30, 13)
            pct.font = .systemFont(ofSize: 11)
            pct.alignment = .right
            pct.tag = Int(card.id) + 100_000
            view.addSubview(pct)

            let sl = NSSlider(frame: NSMakeRect(34, y + 6, width - 84, 22))
            sl.minValue = card.builtin ? 0.0 : card.brightnessFloor
            sl.maxValue = 1.0
            sl.doubleValue = bri
            sl.tag = Int(card.id)
            sl.target = target
            sl.action = #selector(AppDelegate.adjustBrightness(_:))
            sl.isContinuous = true
            sl.isEnabled = !state.busy
            view.addSubview(sl)
        }

        y -= hResolution
        let resIcon = NSImageView(frame: NSMakeRect(14, y + 10, 14, 14))
        resIcon.image = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: nil)
        resIcon.imageScaling = .scaleProportionallyDown
        view.addSubview(resIcon)

        if !card.modes.isEmpty {
            let pu = NSPopUpButton(frame: NSMakeRect(34, y + 6, width - 48, 22), pullsDown: false)
            pu.font = .systemFont(ofSize: 11.5)
            for m in card.modes { pu.addItem(withTitle: m.label) }
            if let sel = card.selectedModeIndex { pu.selectItem(at: sel) }
            pu.tag = Int(card.id)
            pu.target = target
            pu.action = #selector(AppDelegate.changeResolution(_:))
            pu.isEnabled = !state.busy
            view.addSubview(pu)
        } else {
            let lbl = NSTextField(labelWithString: card.resolution)
            lbl.frame = NSMakeRect(34, y + 11, width - 48, 14)
            lbl.font = .systemFont(ofSize: 12)
            view.addSubview(lbl)
        }

        return view
    }

    private static func lidRow(_ state: PopupState, target: AnyObject) -> (NSView, CGFloat) {
        let view = NSView(frame: NSMakeRect(0, 0, width, hLid))
        let label = NSTextField(labelWithString: L10n.t("Keep awake with lid closed"))
        label.frame = NSMakeRect(14, 11, width - 80, 14)
        label.font = .systemFont(ofSize: 12)
        view.addSubview(label)

        if state.lid == .unknown {
            let hint = NSTextField(labelWithString: L10n.t("unknown state"))
            hint.frame = NSMakeRect(width - 140, 11, 80, 14)
            hint.font = .systemFont(ofSize: 10)
            hint.textColor = .tertiaryLabelColor
            hint.alignment = .right
            view.addSubview(hint)
        }

        let sw = NSSwitch(frame: NSMakeRect(width - 54, 7, 44, 22))
        sw.state = state.lid == .on ? .on : .off
        sw.target = target
        sw.action = #selector(AppDelegate.toggleLid(_:))
        sw.isEnabled = state.lidCanToggle && !state.busy
        view.addSubview(sw)
        return (view, hLid)
    }

    private static func loginRow(_ state: PopupState, target: AnyObject) -> (NSView, CGFloat) {
        let view = NSView(frame: NSMakeRect(0, 0, width, hLogin))
        let label = NSTextField(labelWithString: L10n.t("Open at login"))
        label.frame = NSMakeRect(14, 11, width - 80, 14)
        label.font = .systemFont(ofSize: 12)
        view.addSubview(label)

        let sw = NSSwitch(frame: NSMakeRect(width - 54, 7, 44, 22))
        sw.state = state.loginItemEnabled ? .on : .off
        sw.target = target
        sw.action = #selector(AppDelegate.toggleLoginItem(_:))
        sw.isEnabled = state.loginItemAvailable && !state.busy
        view.addSubview(sw)
        return (view, hLogin)
    }

    private static func separator(at y: CGFloat) -> NSView {
        let v = NSView(frame: NSMakeRect(0, y, width, hSeparator))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }
}
