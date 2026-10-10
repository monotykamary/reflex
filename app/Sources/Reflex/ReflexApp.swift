import AppKit
import Combine
import SwiftUI

// Reflex: one place to see, answer and talk to every coding agent in herdr.
// A regular app (Dock, ⌘Tab, menu bar) by default, with an edge rail, a ⌥⌥
// command bar, an inbox and per-agent terminals. Decisions happen in reflexd.

@main
struct ReflexMain {
    static func main() {
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
        command.openSetup = { [weak self] step in self?.showSettings(pane: step == .jev ? .routing : .setup) }
        SetupState.shared.start()
        hotkey = DoubleOption { [weak self] in
            if Onboarding.shared.consumeHotkey() { return }
            self?.toggleBar()
        }
        hotkey?.start()
        if !Settings.shared.onboarded && ProcessInfo.processInfo.environment["REFLEX_SHOW"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showOnboarding() }
        }
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
        if !hasVisibleWindows {
            if let w = popouts.values.first {
                w.makeKeyAndOrderFront(nil)
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
                if let t = env["REFLEX_DEMO_TYPED"] { self.command.text = t }
                if env["REFLEX_DEMO_PIN"] != nil { self.command.target = Store.shared.state.agents.first?.pane }
                if let t = ProcessInfo.processInfo.environment["REFLEX_DEMO_TEXT"] {
                    self.command.text = t
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.command.submit(agents: Store.shared.state.agents) }
                }
            case "inbox": self.showInbox()
            case "settings": self.showSettings()
            case "agents":
                if let s = NSScreen.main { self.edge.show(on: s, y: s.visibleFrame.midY, hold: 3600) }
                RailModel.shared.panel = .agents
            case "rail": if let s = NSScreen.main { self.edge.show(on: s, y: s.visibleFrame.midY, hold: 3600) }
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
            default: if let a = Store.shared.state.agents.first { self.showPane(a.pane) }
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
                        openAgent: { [weak self] a in self?.showPane(a.pane) },
                        openBar: { [weak self] a in self?.openBar(pinned: a) },
                        reveal: { a in HerdrWindow.reveal(pane: a.pane) },
                        openSettings: { [weak self] in self?.showSettings() },
                        restart: { Daemon.shared.restart() },
                        openLog: { NSWorkspace.shared.open(Daemon.logURL) },
                        quit: { NSApp.terminate(nil) })
        let p = Panels.floating(view, size: NSSize(width: 30, height: 100), key: true)
        p.level = .statusBar
        p.ignoresMouseEvents = true
        strip = p

        let sl = Panels.floating(Sliver(), size: NSSize(width: 14, height: 120), key: false)
        sl.level = .statusBar
        sl.ignoresMouseEvents = true
        sliver = sl

        placeStrip()
        p.orderFrontRegardless()
        sl.orderFrontRegardless()

        edge.panel = { [weak self] in self?.strip }
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
        edge.othersKey = { [weak self] in
            (self?.bar?.isVisible ?? false) || (self?.inbox?.isVisible ?? false)
        }
        edge.onReveal = { Onboarding.shared.noteEdgeReveal() }
        edge.start()

        // Open: size up now. Closed: wait for the exit animation, then size down.
        RailModel.shared.$visible.removeDuplicates().sink { [weak self] open in
            DispatchQueue.main.asyncAfter(deadline: .now() + (open ? 0 : 0.22)) {
                guard RailModel.shared.visible == open else { return }
                self?.placeStrip()
            }
        }.store(in: &bag)
        Store.shared.$state.map { Rail.active($0.agents).map(\.status) + [$0.agents.count.description] }
            .removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !RailModel.shared.visible { self.strip?.ignoresMouseEvents = !self.tabShown }
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
    }

    /// The tab is a sliver of panel at the edge; the open rail is a wider one.
    private func placeStrip() {
        guard let p = strip else { return }
        let s = (railScreen ?? NSScreen.main)?.visibleFrame ?? Panels.screen
        let y0 = railY ?? s.midY
        let size: NSSize
        if RailModel.shared.visible {
            size = NSSize(width: 430, height: min(s.height, 640))
        } else {
            let n = CGFloat(max(1, min(8, Rail.active(Store.shared.state.agents).count)))
            size = NSSize(width: 30, height: 42 + 22 * n - 11)
        }
        let y = min(max(y0 - size.height / 2, s.minY), s.maxY - size.height)
        p.setFrame(NSRect(x: s.maxX - size.width, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: Command bar — shown instantly (used all day; no entrance animation)

    @objc func toggleBar() {
        if let b = bar, b.isVisible { hideBar(); return }
        if bar == nil {
            let p = Panels.floating(CommandBar(model: command), size: NSSize(width: 720, height: 560), key: true)
            p.onEscape = { [weak self] in self?.command.escape() }
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
        let s = Panels.screen
        bar!.setFrameOrigin(NSPoint(x: s.midX - 360, y: s.minY + s.height * 0.78 - 560))
        bar!.alphaValue = 1
        bar!.makeKeyAndOrderFront(nil)
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
        Panels.fadeOut(b) { [weak self] in self?.command.reset() }
    }

    // MARK: Inbox — grows out of the rail

    @objc func showInbox() {
        if inbox == nil {
            let view = InboxView(openPane: { [weak self] p in self?.showPane(p) },
                                 close: { [weak self] in self?.hideInbox() })
            let p = Panels.floating(view, size: NSSize(width: 552, height: 760), key: true)
            p.onEscape = { [weak self] in self?.hideInbox() }
            inbox = p
        }
        if inbox!.isVisible && InboxModel.shared.shown { hideInbox(); return }
        let s = Panels.screen
        let h = min(760, s.height * 0.86)
        inbox!.setFrame(NSRect(x: s.maxX - 60 - 552, y: s.midY - h / 2, width: 552, height: h), display: true)
        inbox!.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { InboxModel.shared.shown = true }
    }

    private func hideInbox() {
        InboxModel.shared.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            if !InboxModel.shared.shown { self?.inbox?.orderOut(nil) }
        }
    }

    // MARK: Agent terminals

    func showPane(_ pane: String) {
        edge.hide(returnFocus: false)
        if let w = popouts[pane] {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
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
        w.tabbingMode = .preferred
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
        popouts[pane] = w
        NSApp.activate()
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
            w.appearance = NSAppearance(named: .darkAqua)
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
        NSApp.activate()
        onboarding!.makeKeyAndOrderFront(nil)
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
        NSApp.activate()
        settings!.makeKeyAndOrderFront(nil)
    }
}
