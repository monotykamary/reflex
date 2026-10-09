import AppKit
import Combine
import SwiftUI

// Reflex: one place to see, answer and talk to every coding agent in herdr.
// A menu-bar app (no Dock icon) with an edge strip, a ⌥⌥ command bar, an
// inbox and per-agent popouts. All decisions happen in reflexd.

@main
struct ReflexMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var strip: KeyPanel?
    private var bar: KeyPanel?
    private var inbox: KeyPanel?
    private var settings: NSWindow?
    private var popouts: [String: NSWindow] = [:]
    private let command = CommandModel()
    private var hotkey: DoubleOption?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        Daemon.shared.start()
        Store.shared.start()
        setupMenu()
        setupStrip()
        command.close = { [weak self] in self?.hideBar() }
        hotkey = DoubleOption { [weak self] in
            if Onboarding.shared.consumeHotkey() { return }
            self?.toggleBar()
        }
        hotkey?.start()
        command.openSetup = { [weak self] step in self?.showOnboarding(at: step) }
        if !Settings.shared.onboarded && ProcessInfo.processInfo.environment["REFLEX_SHOW"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showOnboarding() }
        }
        Settings.shared.$showStrip.sink { [weak self] show in
            DispatchQueue.main.async { show ? self?.strip?.orderFrontRegardless() : self?.strip?.orderOut(nil) }
        }.store(in: &bag)
        Store.shared.$state.map(\.agents.count).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.placeStrip() }
        }.store(in: &bag)
        if let show = ProcessInfo.processInfo.environment["REFLEX_SHOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                switch show {
                case "bar":
                    self?.toggleBar()
                    if let t = ProcessInfo.processInfo.environment["REFLEX_DEMO_TEXT"], let self {
                        self.command.text = t
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            self.command.submit(agents: Store.shared.state.agents)
                        }
                    }
                case "inbox": self?.showInbox()
                case "settings": self?.showSettings()
                case "rail": RailModel.shared.hover(true)
                case "none": break
                case "onboarding": self?.showOnboarding(at: Onboarding.Step(rawValue: Int(ProcessInfo.processInfo.environment["REFLEX_STEP"] ?? "0") ?? 0) ?? .welcome)
                default: if let a = Store.shared.state.agents.first { self?.showPane(a.pane) }
                }
            }
        }
        Store.shared.$state.map(\.inbox.count).removeDuplicates().sink { [weak self] n in
            self?.status.button?.title = n > 0 ? " \(n)" : ""
        }.store(in: &bag)
    }

    func applicationWillTerminate(_ note: Notification) {
        Daemon.shared.stop()
    }

    // Menu bar

    private func setupMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Reflex")
        status.button?.imagePosition = .imageLeading
        let m = NSMenu()
        m.addItem(item("Ask… (⌥⌥)", #selector(toggleBar)))
        m.addItem(item("Inbox", #selector(showInbox), key: "i"))
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(showSettings), key: ","))
        m.addItem(item("Setup Guide…", #selector(openGuide)))
        m.addItem(item("Restart reflexd", #selector(restartDaemon)))
        m.addItem(item("Open log", #selector(openLog)))
        m.addItem(.separator())
        m.addItem(item("Quit Reflex", #selector(quit), key: "q"))
        status.menu = m
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func restartDaemon() { Daemon.shared.restart() }
    @objc private func openLog() { NSWorkspace.shared.open(Daemon.logURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    // Rail

    private let railNarrow: CGFloat = 46
    private let railWide: CGFloat = 560

    private let edge = EdgeReveal()
    private var railScreen: NSScreen?
    private var railY: CGFloat?

    private func setupStrip() {
        let view = Rail(openInbox: { [weak self] in self?.showInbox() },
                        openAgent: { [weak self] a in self?.showPane(a.pane) },
                        openBar: { [weak self] in self?.toggleBar() })
        let p = Panels.floating(view, size: NSSize(width: railNarrow, height: 300), key: false)
        p.level = .statusBar
        p.ignoresMouseEvents = true
        strip = p
        placeStrip()
        if Settings.shared.showStrip { p.orderFrontRegardless() }
        RailModel.shared.$wide.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.placeStrip() }
        }.store(in: &bag)
        edge.panel = { [weak self] in self?.strip }
        edge.place = { [weak self] screen, y in
            self?.railScreen = screen
            self?.railY = y
            self?.placeStrip()
        }
        edge.keepOpen = { InboxModel.shared.shown }
        edge.onReveal = { Onboarding.shared.noteEdgeReveal() }
        edge.start()
        Store.shared.$peek.map { $0?.id }.removeDuplicates().sink { [weak self] id in
            guard id != nil, Settings.shared.surfaceQuestions else { return }
            DispatchQueue.main.async { self?.edge.surface() }
        }.store(in: &bag)
    }

    /// Size the rail panel and keep it at the height where it was summoned.
    private func placeStrip() {
        guard let p = strip else { return }
        let s = (railScreen ?? NSScreen.main)?.visibleFrame ?? Panels.screen
        let w = RailModel.shared.wide ? railWide : railNarrow
        let h = min(s.height * 0.9, CGFloat(170 + 46 * Store.shared.state.agents.count))
        let y = min(max((railY ?? s.midY) - h / 2, s.minY), s.maxY - h)
        p.setFrame(NSRect(x: s.maxX - w, y: y, width: w, height: h), display: true)
    }

    // Command bar — shown instantly (used all day; no entrance animation)

    @objc func toggleBar() {
        if let b = bar, b.isVisible { hideBar(); return }
        if bar == nil {
            let p = Panels.floating(CommandBar(model: command), size: NSSize(width: 720, height: 560), key: true)
            p.onEscape = { [weak self] in self?.command.escape() }
            p.onResign = { [weak self] in
                // Clicking elsewhere closes the bar only while you are typing;
                // a request in flight keeps showing where it went.
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

    private func hideBar() {
        guard let b = bar, b.isVisible else { return }
        Panels.fadeOut(b) { [weak self] in self?.command.reset() }
    }

    // Inbox — grows out of the rail

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
        inbox!.setFrame(NSRect(x: s.maxX - railNarrow - 540, y: s.midY - h / 2, width: 552, height: h), display: true)
        inbox!.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { InboxModel.shared.shown = true }
    }

    private func hideInbox() {
        InboxModel.shared.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            if !InboxModel.shared.shown { self?.inbox?.orderOut(nil) }
        }
    }

    // Popouts

    func showPane(_ pane: String) {
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
        w.contentView = NSHostingView(rootView: AgentPopout(session: session))
        w.isReleasedWhenClosed = false
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

    // Onboarding

    private var onboarding: NSWindow?

    @objc private func openGuide() { showOnboarding() }

    func showOnboarding(at step: Onboarding.Step = .welcome) {
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

    // Settings

    @objc func showSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Reflex Settings"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settings = w
        }
        NSApp.activate()
        settings!.makeKeyAndOrderFront(nil)
    }
}
