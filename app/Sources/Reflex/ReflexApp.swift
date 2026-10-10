import AppKit
import Combine
import SwiftUI

// Reflex: one place to see, answer and talk to every coding agent in herdr.
// A regular app (Dock, ⌘Tab, menu bar) by default, with an edge rail, a ⌥⌥
// command bar, an inbox and per-agent terminals. Decisions happen in reflexd.

@main
struct ReflexMain {
    static func main() {
        // Launched from inside a herdr pane (`open -a Reflex`, a dev build),
        // Reflex inherits that pane's HERDR_* variables, and every herdr it
        // starts — the client opened in Ghostty, the terminal attaches —
        // would think it is nested and refuse. Reflex is never inside a pane.
        // (HERDR_SESSION stays: it names which herdr to talk to.)
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("HERDR_") && key != "HERDR_SESSION" {
            unsetenv(key)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(Settings.shared.showInDock ? .regular : .accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var current: AppDelegate?
    private var status: NSStatusItem?
    private var strip: KeyPanel?
    private var sliver: KeyPanel?
    private var bar: KeyPanel?
    private var inbox: KeyPanel?
    private var pairing: KeyPanel?
    private var settings: NSWindow?
    private var popouts: [String: NSWindow] = [:]
    private let command = CommandModel()
    private var hotkey: DoubleOption?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.current = self
        Daemon.shared.start()
        Store.shared.start()
        setupMainMenu()
        setupStatusItem()
        setupRail()
        command.close = { [weak self] in self?.hideBar() }
        command.openPane = { [weak self] pane in self?.showPane(pane) }
        command.openSetup = { [weak self] step in self?.showSettings(pane: step == .jev ? .routing : .setup) }
        SetupState.shared.start()
        SessionArchive.shared.start()
        hotkey = DoubleOption { [weak self] in
            if Onboarding.shared.consumeHotkey() { return }
            self?.toggleBar()
        }
        hotkey?.start()
        AccessGuide.shared.onGranted = { [weak self] in
            self?.hotkey?.restart()
            Onboarding.shared.refresh()
            SetupState.shared.update()
            // Back to where the user asked for it.
            if let w = self?.onboarding, w.isVisible { AppDelegate.activateSelf(); w.makeKeyAndOrderFront(nil) }
            else if let w = self?.settings, w.isVisible { AppDelegate.activateSelf(); w.makeKeyAndOrderFront(nil) }
        }
        if !Settings.shared.onboarded && ProcessInfo.processInfo.environment["REFLEX_SHOW"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showOnboarding() }
        }
        Settings.shared.applyAppearance()
        // Terminals follow the appearance: TokyoNight by night, TokyoNight Day by day.
        NSApp.publisher(for: \.effectiveAppearance).removeDuplicates { $0.name == $1.name }.sink { _ in
            DispatchQueue.main.async { Themes.shared.refresh() }
        }.store(in: &bag)
        Settings.shared.$appearance.dropFirst().removeDuplicates().sink { _ in
            DispatchQueue.main.async { Settings.shared.applyAppearance() }
        }.store(in: &bag)
        Settings.shared.$showInDock.dropFirst().removeDuplicates().sink { dock in
            NSApp.setActivationPolicy(dock ? .regular : .accessory)
        }.store(in: &bag)
        Store.shared.$state.map(\.inbox.count).removeDuplicates().sink { [weak self] n in
            self?.status?.button?.title = n > 0 ? " \(n)" : ""
            NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
        }.store(in: &bag)
        debugShow()
    }

    func applicationWillTerminate(_ note: Notification) {
        Daemon.shared.stop()
    }

    /// ⌘Tab or a Dock click with nothing open: bring back the terminals, or the inbox.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if Date().timeIntervalSince(AppDelegate.selfActivatedAt) < 2 { return true }
        if !hasVisibleWindows {
            if let w = popouts.values.first {
                bringForward(w)
            } else {
                showInbox()
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func debugShow() {
        guard let show = ProcessInfo.processInfo.environment["REFLEX_SHOW"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            switch show {
            case "bar":
                self.toggleBar()
                // Dev: fill or pin without sending, to check the bar's layout.
                let env = ProcessInfo.processInfo.environment
                // Dev: type a sequence ("sd|s||sd"), one step every 0.7 s.
                if let seq = env["REFLEX_DEMO_SEQ"] {
                    Task {
                        for step in seq.components(separatedBy: "|") {
                            self.command.text = step
                            try? await Task.sleep(for: .milliseconds(700))
                        }
                    }
                }
                if let t = env["REFLEX_DEMO_TYPED"] {
                    Task {
                        for _ in 0..<40 where Store.shared.state.folders == 0 && !t.hasPrefix("/") {
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                        self.command.text = t
                    }
                }
                if env["REFLEX_DEMO_PIN"] != nil { self.command.target = Store.shared.state.agents.first?.pane }
                if let t = ProcessInfo.processInfo.environment["REFLEX_DEMO_TEXT"] {
                    self.command.text = t
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.command.submit() }
                }
            case "inbox": self.showInbox()
            case "pairing": self.showPairing()
            case "access": AccessGuide.shared.start(preview: true)
            case "settings": self.showSettings()
            case "railclick":
                // Dev: the rail as its column, then the dots "clicked" a moment later.
                if let s = NSScreen.main { self.edge.show(on: s, y: s.visibleFrame.midY, hold: 3600) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { RailModel.shared.panel = .agents }
            case "agents":
                if let s = NSScreen.main { self.edge.show(on: s, y: s.visibleFrame.midY, hold: 3600) }
                RailModel.shared.panel = .agents
            case "rail":
                // Dev: REFLEX_DEMO_TOP opens it near the top, away from the tab.
                let top = ProcessInfo.processInfo.environment["REFLEX_DEMO_TOP"] != nil
                if let s = NSScreen.main { self.edge.show(on: s, y: top ? s.visibleFrame.maxY - 140 : s.visibleFrame.midY, hold: 3600) }
                // Dev: close it again, to watch the exit.
                if ProcessInfo.processInfo.environment["REFLEX_DEMO_HIDE"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.edge.hide() }
                }
            case "none": break
            case "onboarding":
                let step = Int(ProcessInfo.processInfo.environment["REFLEX_STEP"] ?? "0") ?? 0
                self.showOnboarding(at: Onboarding.Step(rawValue: step) ?? .welcome)
                if let t = ProcessInfo.processInfo.environment["REFLEX_DEMO_TEXT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        Onboarding.shared.trialText = t
                        Onboarding.shared.tryRoute()
                    }
                }
            default:
                let want = ProcessInfo.processInfo.environment["REFLEX_DEMO_PANE"]
                if let a = Store.shared.state.agents.first(where: { $0.pane == want }) ?? Store.shared.state.agents.first {
                    self.showPane(a.pane)
                    // Dev: with another app in front, switch to it from the bar.
                    if ProcessInfo.processInfo.environment["REFLEX_DEMO_SWITCH"] != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            self.toggleBar()
                            self.command.text = ProcessInfo.processInfo.environment["REFLEX_DEMO_SWITCH_TEXT"] ?? "reflex"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.command.submit() }
                        }
                    }
                    // Dev: minimize it, then switch to it again as the bar would.
                    if ProcessInfo.processInfo.environment["REFLEX_DEMO_REOPEN"] != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.popouts[a.pane]?.miniaturize(nil) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.showPane(a.pane) }
                    }
                }
            }
        }
    }

    // MARK: Menus

    private func item(_ title: String, _ sel: Selector, key: String = "", mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target ?? self
        return i
    }

    /// A real menu bar, so ⌘, ⌘Q ⌘W ⌘C ⌘V ⌘M work wherever Reflex has focus.
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Reflex")
        app.addItem(item("About Reflex", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(showSettings as () -> Void), key: ","))
        app.addItem(item("Welcome Tour…", #selector(openGuide)))
        app.addItem(.separator())
        app.addItem(item("Ask…", #selector(toggleBar), key: " ", mods: [.option]))
        app.addItem(item("Inbox", #selector(showInbox), key: "i", mods: [.command, .shift]))
        app.addItem(item("Restart reflexd", #selector(restartDaemon)))
        app.addItem(.separator())
        app.addItem(item("Hide Reflex", #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        app.addItem(item("Quit Reflex", #selector(quit), key: "q"))
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private func setupStatusItem() {
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        s.button?.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Reflex")
        s.button?.imagePosition = .imageLeading
        let m = NSMenu()
        m.addItem(item("Ask… (⌥⌥)", #selector(toggleBar), key: ""))
        m.addItem(item("Inbox", #selector(showInbox), key: ""))
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(showSettings as () -> Void), key: ""))
        m.addItem(item("Restart reflexd", #selector(restartDaemon), key: ""))
        m.addItem(item("Open log", #selector(openLog), key: ""))
        m.addItem(.separator())
        m.addItem(item("Quit Reflex", #selector(quit), key: ""))
        s.menu = m
        status = s
    }

    @objc private func restartDaemon() { Daemon.shared.restart() }
    @objc private func openLog() { NSWorkspace.shared.open(Daemon.logURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Rail

    private let edge = EdgeReveal()
    private var railScreen: NSScreen?
    private var railY: CGFloat?

    private var tabShown: Bool {
        Settings.shared.showStrip && !Rail.active(Store.shared.state.agents).isEmpty
    }

    private func setupRail() {
        let view = Rail(openInbox: { [weak self] in self?.showInbox() },
                        openBar: { [weak self] a in self?.openBar(pinned: a) },
                        openSettings: { [weak self] in self?.showSettings() },
                        restart: { Daemon.shared.restart() },
                        openLog: { NSWorkspace.shared.open(Daemon.logURL) },
                        openPhone: { [weak self] in self?.showPairing() },
                        quit: { NSApp.terminate(nil) })
        // Neither rail window ever becomes key (see RailKeys); clicks still land.
        let p = Panels.floating(view, size: NSSize(width: 30, height: 100), key: false)
        p.level = .statusBar
        p.ignoresMouseEvents = true
        strip = p

        let kc = Panels.floating(RailKeys(), size: NSSize(width: 1, height: 1), key: true)
        kc.level = .statusBar
        kc.ignoresMouseEvents = true
        kc.alphaValue = 0
        railKeys = kc

        let sideView = RailSide(openAgent: { [weak self] a in self?.showPane(a.pane) },
                                openBar: { [weak self] a in self?.openBar(pinned: a) },
                                reveal: { a in HerdrWindow.reveal(pane: a.pane) })
        let sp = Panels.floating(sideView, size: NSSize(width: 1, height: 1), key: false)
        sp.level = .statusBar
        sp.ignoresMouseEvents = true
        side = sp

        let tw = Panels.floating(RailTab(), size: NSSize(width: 30, height: 100), key: false)
        tw.level = .statusBar
        tw.ignoresMouseEvents = true
        tabWindow = tw

        let sl = Panels.floating(Sliver(), size: NSSize(width: 14, height: 120), key: false)
        sl.level = .statusBar
        sl.ignoresMouseEvents = true
        sliver = sl

        placeStrip()
        p.orderFrontRegardless()
        sp.orderFrontRegardless()
        sl.orderFrontRegardless()
        kc.orderFrontRegardless()
        tw.orderFrontRegardless()

        edge.panel = { [weak self] in self?.strip }
        edge.keys = { [weak self] in self?.railKeys }
        edge.side = { [weak self] in self?.side }
        edge.rects = { [weak self] in
            guard let r = self?.railRects() else { return [] }
            return [r.column, r.side].compactMap { $0 }
        }
        edge.tabRect = { [weak self] in self?.tabRect() }
        edge.sliver = { [weak self] in self?.sliver }
        edge.tabShown = { [weak self] in self?.tabShown ?? false }
        edge.anchor = { [weak self] in
            guard let self, let s = self.railScreen ?? NSScreen.main else { return nil }
            return (s, self.railY ?? s.visibleFrame.midY)
        }
        edge.place = { [weak self] screen, y in
            self?.railScreen = screen
            self?.railY = y
            self?.placeStrip()
        }
        edge.keepOpen = { InboxModel.shared.shown }
        // Quiet only while the bar or the inbox actually has the keys: one
        // left up behind another window must not deaden the edge.
        edge.othersKey = { [weak self] in
            guard let self else { return false }
            let bar = self.bar.map { $0.isVisible && $0.isKeyWindow && self.command.shown } ?? false
            let inbox = self.inbox.map { $0.isVisible && $0.isKeyWindow && InboxModel.shared.shown } ?? false
            return bar || inbox
        }
        edge.onReveal = { Onboarding.shared.noteEdgeReveal() }
        edge.start()
        // A pairing code never outlives the app that made it.
        Pairing.shared.stop()
        KeepAwake.shared.start()
        BackgroundWatch.shared.start()
        Store.shared.watching = { [weak self] in
            self?.popouts.first { $0.value.isKeyWindow }?.key
        }

        // Closed: the tab comes back where the rail was.
        RailModel.shared.$visible.removeDuplicates().sink { [weak self] open in
            guard let self, !open else { return }
            self.tabY = self.railY
            self.tabScreen = self.railScreen
            DispatchQueue.main.async { self.placeStrip() }
        }.store(in: &bag)
        Store.shared.$state.map { Rail.active($0.agents).map(\.status) + [$0.agents.count.description] }
            .removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.placeStrip()
                }
            }.store(in: &bag)
        Settings.shared.$showStrip.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.placeStrip() }
        }.store(in: &bag)
        Store.shared.$peek.map { $0?.id }.removeDuplicates().sink { [weak self] id in
            guard id != nil, Settings.shared.surfaceQuestions else { return }
            DispatchQueue.main.async { self?.edge.surface() }
        }.store(in: &bag)
        setupClickAway()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.placeStrip() }
        }
        // No surface's window resizes or moves while it shows (macOS draws
        // the old content shifted for a frame when it does — the jumps).
        // Each is as large as it can need and clear; the window takes the
        // mouse only over what it shows, and clicks elsewhere go through.
        mouseGate = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMouse() }
        }
    }

    private var clickMonitors: [Any] = []

    /// A click anywhere else closes the inbox, and the rail when it lands
    /// beyond the rail's dead zone — each with its usual exit. (Watching
    /// mouse clicks in other apps needs no permission.)
    private func setupClickAway() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            let p = NSEvent.mouseLocation
            Task { @MainActor in self?.clickAway(at: p, in: nil) }
        } as Any)
        clickMonitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            let p = NSEvent.mouseLocation
            let w = e.window
            Task { @MainActor in self?.clickAway(at: p, in: w) }
            return e
        } as Any)
    }

    private func clickAway(at p: NSPoint, in window: NSWindow?) {
        let mine = [strip, side, railKeys, inbox, pairing].compactMap { $0 }
        if let window, mine.contains(where: { $0 === window }) { return }
        if InboxModel.shared.shown, !(inboxRect()?.contains(p) ?? false) {
            hideInbox()
        }
        // (Dev launches that pin the rail open for a screenshot keep it open.)
        let pinned = ProcessInfo.processInfo.environment["REFLEX_SHOW"].map { ["rail", "agents", "railclick"].contains($0) } ?? false
        if RailModel.shared.visible && !Settings.shared.railAlways && !pinned && !edge.near(p) {
            // The click is activating whatever it landed on; leave focus to it.
            edge.hide(returnFocus: false)
        }
    }

    private var side: KeyPanel?
    /// The edge tab's own window, and where it sits (it stays put while the
    /// rail opens elsewhere; it settles where the rail last was once closed).
    private var tabWindow: KeyPanel?
    private var tabY: CGFloat?
    private var tabScreen: NSScreen?
    private var railKeys: KeyPanel?
    private var placeQueued = false

    /// Coalesce: many changes in one turn of the run loop, one placement.
    private func schedulePlace() {
        guard !placeQueued else { return }
        placeQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.placeQueued = false
            self?.placeStrip()
        }
    }

    /// The rail's windows: each spans its screen's height at the right edge
    /// and stays put while shown — the column's, the side's just left of it,
    /// the tab's. What they show is placed inside them (see `Anchored`).
    static let columnWindowWidth: CGFloat = 80
    static let sideWindowWidth: CGFloat = 560

    private func placeStrip() {
        guard let p = strip else { return }
        let s = (railScreen ?? NSScreen.main)?.visibleFrame ?? Panels.screen
        let rail = RailModel.shared
        let anchor = (s.maxY - (railY ?? s.midY)).rounded()
        if rail.anchor != anchor { rail.anchor = anchor }
        let column = NSRect(x: s.maxX - AppDelegate.columnWindowWidth, y: s.minY, width: AppDelegate.columnWindowWidth, height: s.height)
        if p.frame != column { p.setFrame(column, display: true) }
        if let sp = side {
            let f = NSRect(x: s.maxX - Rail.columnWidth - AppDelegate.sideWindowWidth, y: s.minY,
                           width: AppDelegate.sideWindowWidth, height: s.height)
            if sp.frame != f { sp.setFrame(f, display: true) }
        }
        if let tw = tabWindow {
            let ts = (tabScreen ?? railScreen ?? NSScreen.main)?.visibleFrame ?? s
            let ty = tabY ?? railY ?? ts.midY
            let ta = (ts.maxY - ty).rounded()
            if rail.tabAnchor != ta { rail.tabAnchor = ta }
            let f = NSRect(x: ts.maxX - 30, y: ts.minY, width: 30, height: ts.height)
            if tw.frame != f { tw.setFrame(f, display: true) }
        }
    }

    /// Where `size` sits, anchored at `y` from the top, at the right of `f`.
    private func anchored(_ size: CGSize, at y: CGFloat, in f: NSRect) -> NSRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let top = Anchored.top(y, height: size.height, in: f.height)
        return NSRect(x: f.maxX - size.width, y: f.maxY - top - size.height, width: size.width, height: size.height)
    }

    /// Where the open rail's content is on screen: the column, and what is
    /// beside it when that takes clicks (a dot's pill never does).
    private func railRects() -> (column: NSRect?, side: NSRect?) {
        let rail = RailModel.shared
        guard rail.visible, let p = strip else { return (nil, nil) }
        let column = anchored(rail.columnSize, at: rail.anchor, in: p.frame)
        var beside: NSRect?
        if let sp = side {
            switch Rail.side(rail, Store.shared, inboxShown: InboxModel.shared.shown) {
            case .none, .pill: break
            default: beside = anchored(rail.sideSize, at: rail.anchor, in: sp.frame)
            }
        }
        return (column, beside)
    }

    private func tabRect() -> NSRect? {
        guard let tw = tabWindow, tabShown, !RailModel.shared.visible else { return nil }
        return anchored(CGSize(width: 30, height: Rail.tabHeight(Store.shared.state.agents)),
                        at: RailModel.shared.tabAnchor, in: tw.frame)
    }

    /// The inbox's cards, at the top of its window.
    private func inboxRect() -> NSRect? {
        guard let w = inbox, w.isVisible else { return nil }
        let m = InboxModel.shared.size
        guard m.height > 0 else { return nil }
        let h = min(m.height, w.frame.height)
        return NSRect(x: w.frame.maxX - m.width, y: w.frame.maxY - h, width: m.width, height: h)
    }

    private func updateMouse() {
        let m = NSEvent.mouseLocation
        updateBarMouse()
        func gate(_ w: NSWindow?, _ r: NSRect?) {
            guard let w else { return }
            let take = r?.contains(m) ?? false
            if w.ignoresMouseEvents == take { w.ignoresMouseEvents = !take }
        }
        let r = railRects()
        gate(strip, r.column)
        gate(side, r.side)
        if let ib = inbox, ib.isVisible { gate(ib, inboxRect()) }
    }

    // MARK: Command bar — shown instantly (used all day; no entrance animation)

    @objc func toggleBar() {
        if let b = bar, b.isVisible { hideBar(); return }
        if bar == nil {
            let p = Panels.floating(CommandBar(model: command), size: NSSize(width: 720, height: 560), key: true)
            p.onEscape = { [weak self] in self?.command.escape() }
            p.onPaste = { [weak self] in self?.command.attach(Attachments.read(.general)) ?? false }
            p.onResign = { [weak self] in
                guard let self, let b = self.bar, b.isVisible else { return }
                switch self.command.phase {
                case .typing, .failed: self.hideBar()
                default: break
                }
            }
            bar = p
        }
        command.reset()
        // ⌘Tab-like: if you're in a session's terminal, ⏎ goes to the one before it.
        command.frontPane = popouts.first { $0.value.isKeyWindow || ($0.value.isMainWindow && NSApp.isActive) }?.key
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { command.shown = true }
        placeBar()
        bar!.alphaValue = 1
        bar!.makeKeyAndOrderFront(nil)
    }

    private var barTop: (top: CGFloat, midX: CGFloat) {
        let s = Panels.screen
        return (s.minY + s.height * 0.78, s.midX)
    }

    /// Tall enough for the longest list; the bar sits at its top.
    static let barHeight: CGFloat = 600

    private var mouseGate: Timer?

    private func placeBar() {
        guard let b = bar else { return }
        let top = barTop.top.rounded()
        b.setFrame(NSRect(x: (barTop.midX - 360).rounded(), y: top - AppDelegate.barHeight,
                          width: 720, height: AppDelegate.barHeight), display: true)
    }

    /// Over the visible bar the window takes the mouse; elsewhere clicks go
    /// through to whatever is underneath.
    private func updateBarMouse() {
        guard let b = bar, b.isVisible else { return }
        let f = b.frame
        let h = command.size == .zero ? f.height : min(f.height, command.size.height)
        let visible = NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
        let over = visible.contains(NSEvent.mouseLocation)
        if b.ignoresMouseEvents == over { b.ignoresMouseEvents = !over }
    }

    /// From the rail: close it without handing the keys back, then open the
    /// bar (pinned to an agent, when one was picked).
    func openBar(pinned: AgentInfo?) {
        edge.hide(returnFocus: false)
        if let b = bar, b.isVisible { b.makeKey() } else { toggleBar() }
        if let a = pinned { command.target = a.pane }
    }

    private func hideBar() {
        guard let b = bar, b.isVisible else { return }
        guard command.shown else { b.orderOut(nil); return }
        command.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            guard let self, !self.command.shown else { return }
            b.orderOut(nil)
            self.command.reset()
        }
    }

    // MARK: Take Reflex with you — a one-time QR beside the rail

    @objc func showPairing() {
        edge.hide(returnFocus: false)
        if InboxModel.shared.shown { hideInbox() }
        if pairing == nil {
            let view = PairingHost(done: { [weak self] in self?.hidePairing() })
            let p = Panels.floating(view, size: NSSize(width: 340, height: 560), key: true)
            p.onEscape = { [weak self] in self?.hidePairing() }
            pairing = p
        }
        guard let w = pairing else { return }
        let s = (railScreen ?? NSScreen.main)?.visibleFrame ?? Panels.screen
        let y = min(max((railY ?? s.midY) - 280, s.minY), s.maxY - 560)
        w.setFrame(NSRect(x: s.maxX - Rail.columnWidth - 12 - 340, y: y, width: 340, height: 560), display: true)
        Pairing.shared.start()
        AppDelegate.activateSelf()
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { Pairing.shared.shown = true }
    }

    private func hidePairing() {
        Pairing.shared.shown = false
        Pairing.shared.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            if !Pairing.shared.shown { self?.pairing?.orderOut(nil) }
        }
    }

    // MARK: Inbox — grows out of the rail

    @objc func showInbox() {
        if inbox == nil {
            let view = InboxView(openPane: { [weak self] p in self?.showPane(p) },
                                 close: { [weak self] in self?.hideInbox() })
            let p = Panels.floating(view, size: NSSize(width: InboxView.width, height: 320), key: true)
            p.onEscape = { [weak self] in self?.hideInbox() }
            inbox = p
        }
        if inbox!.isVisible && InboxModel.shared.shown { hideInbox(); return }
        edge.hide(returnFocus: false)
        InboxModel.shared.maxList = inboxMaxHeight - 120
        placeInbox()
        inbox!.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { InboxModel.shared.shown = true }
    }

    private var inboxMaxHeight: CGFloat { min(760, Panels.screen.height * 0.86) }

    /// Beside the rail: a window as tall as the inbox may grow, placed once
    /// as it opens; the cards sit at its top and it never resizes under them.
    private func placeInbox() {
        guard let w = inbox else { return }
        let s = Panels.screen
        let h = inboxMaxHeight
        let f = NSRect(x: (s.maxX - Rail.columnWidth - 16 - InboxView.width).rounded(), y: (s.midY - h / 2).rounded(),
                       width: InboxView.width, height: h.rounded())
        if w.frame != f { w.setFrame(f, display: true) }
    }

    private func hideInbox() {
        InboxModel.shared.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            if !InboxModel.shared.shown { self?.inbox?.orderOut(nil) }
        }
    }

    // MARK: Agent terminals

    /// An agent's terminal that is already open, brought to you wherever it
    /// is: on another Space or behind a full-screen app (it moves here),
    /// minimized, a background tab, or with Reflex not yet active.
    private func bringForward(_ w: NSWindow) {
        w.collectionBehavior.insert(.moveToActiveSpace)
        if w.isMiniaturized { w.deminiaturize(nil) }
        if let group = w.tabGroup, group.selectedWindow !== w { group.selectedWindow = w }
        NSApp.unhide(nil)
        AppDelegate.activateSelf()
        w.makeKeyAndOrderFront(nil)
        // Activation is cooperative and may land a moment later — or not at
        // all while another app holds it: show the window regardless, then
        // make it key once Reflex is active.
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard !w.isKeyWindow else { return }
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// Make Reflex the active app. From the Ask bar or the rail — panels that
    /// never activate Reflex — the app you were in is still active, and
    /// cooperative activation may turn a plain request down; the window would
    /// show, then lose to that app a moment later. So, when not active, also
    /// ask Launch Services to open Reflex, as a Dock click does.
    /// When activateSelf last went through Launch Services (its reopen
    /// event is ours, not the user's).
    static var selfActivatedAt = Date.distantPast

    static func activateSelf() {
        NSApp.activate()
        guard !NSApp.isActive else { return }
        selfActivatedAt = Date()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }

    /// A session ended from Reflex: its terminal window goes too.
    func closedSession(_ pane: String) {
        popouts[pane]?.close()
        if command.target == pane { command.target = nil }
    }

    func showPane(_ pane: String) {
        // A background session's note: attach it in herdr (then it is a pane).
        if pane.hasPrefix("bg:") {
            if InboxModel.shared.shown { hideInbox() }
            BackgroundWatch.open(pane)
            return
        }
        Recents.shared.touch(pane)
        Store.shared.seen(pane)
        edge.hide(returnFocus: false)
        if InboxModel.shared.shown { hideInbox() }
        // The bar goes first, at once: left to fade while still key, it would
        // hand focus back to the app it came from as it left.
        if let b = bar, b.isVisible {
            b.orderOut(nil)
            command.reset()
        }
        if let w = popouts[pane] {
            bringForward(w)
            return
        }
        let session = TerminalSession(pane: pane)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        let a = Store.shared.state.agents.first { $0.pane == pane }
        w.title = a.map { "\($0.kind) · \($0.folder)" } ?? pane
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(hex: Themes.shared.current.background)
        w.appearance = NSAppearance(named: Themes.shared.current.isDark ? .darkAqua : .aqua)
        let titlebar = w.frame.height - w.contentLayoutRect.height
        w.contentView = NSHostingView(rootView: AgentPopout(session: session, titlebar: max(titlebar, 28)))
        w.isReleasedWhenClosed = false
        // One window per session — never merged into tabs, whatever the
        // system's "prefer tabs" setting says.
        w.tabbingMode = .disallowed
        w.center()
        Themes.shared.$current.sink { [weak w] t in
            w?.backgroundColor = NSColor(hex: t.background)
            w?.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in
                session.detach()
                self?.popouts[pane] = nil
            }
        }
        // Clicking between terminals counts as switching, for the bar's order.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
            Task { @MainActor in Recents.shared.touch(pane); Store.shared.seen(pane) }
        }
        popouts[pane] = w
        AppDelegate.activateSelf()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(session.view)
    }

    // MARK: Onboarding

    private var onboarding: NSWindow?

    @objc private func openGuide() { showOnboarding() }

    func showOnboarding(at step: Onboarding.Step = .welcome) {
        edge.hide(returnFocus: false)
        if onboarding == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.contentView = NSHostingView(rootView: OnboardingView())
            w.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Task { @MainActor in Onboarding.shared.closed() }
            }
            Onboarding.shared.close = { [weak w] in w?.close() }
            onboarding = w
        }
        Onboarding.shared.begin(at: step)
        onboarding!.center()
        AppDelegate.activateSelf()
        onboarding!.makeKeyAndOrderFront(nil)
        // Seen even if macOS declines to activate Reflex (e.g. at login).
        onboarding!.orderFrontRegardless()
    }

    // MARK: Settings

    @objc func showSettings() { showSettings(pane: nil) }

    func showSettings(pane: SettingsPane?) {
        edge.hide(returnFocus: false)
        if let pane { SettingsNav.shared.pane = pane }
        if settings == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.titlebarSeparatorStyle = .automatic
            w.setContentSize(NSSize(width: 820, height: 620))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ReflexSettings")
            w.center()
            settings = w
        }
        AppDelegate.activateSelf()
        settings!.makeKeyAndOrderFront(nil)
    }
}
