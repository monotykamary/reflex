import AppKit
import Combine
import SwiftTerm
import SwiftUI

// A raw terminal onto one agent: SwiftTerm runs `herdr agent attach <pane>` in
// a PTY, so this is the agent's own TUI — colors, keys, mouse and resizing go
// straight through. Themed with any Ghostty theme (Tokyo Night by default).

@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let pane: String
    let view: LocalProcessTerminalView
    @Published var attached = false
    @Published var ended = false
    private var bag = Set<AnyCancellable>()

    init(pane: String) {
        self.pane = pane
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))
        super.init()
        view.processDelegate = self
        view.optionAsMetaKey = true
        TerminalScroll.install()
        TerminalScroll.views[ObjectIdentifier(view)] = view
        TerminalSelect.install()
        apply(Themes.shared.current, font: Themes.font(Themes.shared.fontFamily, size: Themes.shared.fontSize))
        Themes.shared.$current.combineLatest(Themes.shared.$fontSize, Themes.shared.$fontFamily)
            .sink { [weak self] t, s, f in self?.apply(t, font: Themes.font(f, size: s)) }
            .store(in: &bag)
    }

    func apply(_ t: TermTheme, font: NSFont) {
        view.installColors(t.palette.map { hex in
            let c = NSColor(hex: hex).usingColorSpace(.sRGB) ?? .black
            return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535),
                                   blue: UInt16(c.blueComponent * 65535))
        })
        view.nativeBackgroundColor = NSColor(hex: t.background)
        view.nativeForegroundColor = NSColor(hex: t.foreground)
        view.caretColor = NSColor(hex: t.cursor)
        view.selectedTextBackgroundColor = NSColor(hex: t.selection)
        view.font = font
        view.needsDisplay = true
    }

    /// Attach, retrying quietly: Herdr refuses an attach while a read is in
    /// flight. A terminal takes one attached client; if another holds it (a
    /// window left behind by a Reflex that was killed or crashed), take over:
    /// this window is where you asked to see it.
    func attach() {
        ended = false
        let script = """
        err=$(mktemp -t reflex-attach)
        takeover=""
        for i in 1 2 3 4 5 6 7 8 9 10; do
          herdr agent attach "$1" $takeover 2>"$err" && { rm -f "$err"; exit 0; }
          if grep -q "already has an attached client" "$err"; then takeover=--takeover; continue; fi
          grep -q retry "$err" || { cat "$err"; rm -f "$err"; exit 1; }
          printf '\\033[2J\\033[H'; sleep 0.3
        done
        rm -f "$err"; exit 1
        """
        var env = Daemon.shared.childEnvironment()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        view.startProcess(executable: "/bin/sh", args: ["-c", script, "reflex-attach", pane],
                          environment: env.map { "\($0.key)=\($0.value)" })
        attached = true
    }

    func detach() {
        // The attach runs in its own session (setsid): end the whole group, as
        // herdr's client outlives a closed terminal and would keep the pane.
        if attached, let pid = view.process?.shellPid, pid > 0 { kill(-pid, SIGTERM) }
        if attached { view.terminate() }
        attached = false
        TerminalScroll.views[ObjectIdentifier(view)] = nil
        TerminalSelect.toAgent[ObjectIdentifier(view)] = nil
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.attached = false
            withAnimation(Motion.enter) { self.ended = true }
        }
    }
}

/// Hosts the terminal one scroller-width wider than it shows, so SwiftTerm's
/// legacy scroller (which it always reserves) is clipped off and every visible
/// pixel is a column.
final class TerminalContainer: NSView {
    let term: LocalProcessTerminalView
    static let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    init(term: LocalProcessTerminalView) {
        self.term = term
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(term)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        term.frame = NSRect(x: 0, y: 0, width: bounds.width + TerminalContainer.scrollerWidth, height: bounds.height)
        for case let scroller as NSScroller in term.subviews { scroller.isHidden = true }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> TerminalContainer { TerminalContainer(term: session.view) }
    func updateNSView(_ v: TerminalContainer, context: Context) {}
}

/// Scrolling in an agent terminal. herdr's attach client (like most TUIs) runs
/// in the alternate screen with mouse reporting on, where there is no local
/// scrollback: the wheel must reach the program as mouse wheel events (SGR),
/// or as arrow keys in an alternate screen without mouse reporting. Only a
/// plain shell falls back to SwiftTerm's own scrollback.
@MainActor
enum TerminalScroll {
    private static var monitor: Any?
    private static var carry: CGFloat = 0
    static var views: [ObjectIdentifier: LocalProcessTerminalView] = [:]

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard let view = views.values.first(where: { $0.window === e.window && $0.window != nil }) else { return e }
            let p = view.convert(e.locationInWindow, from: nil)
            guard view.bounds.contains(p) else { return e }
            return handle(e, view: view, at: p) ? nil : e
        }
    }

    private static func handle(_ e: NSEvent, view: LocalProcessTerminalView, at p: NSPoint) -> Bool {
        let t = view.getTerminal()
        let mouse = t.mouseMode != .off
        guard mouse || t.isCurrentBufferAlternate else { return false }
        // Trackpads report many small precise deltas; turn them into whole lines.
        let unit: CGFloat = e.hasPreciseScrollingDeltas ? 18 : 1
        carry += e.scrollingDeltaY / unit
        let lines = Int(carry.rounded(.towardZero))
        guard lines != 0 else { return true }
        carry -= CGFloat(lines)
        let up = lines > 0
        let cols = max(t.cols, 1), rows = max(t.rows, 1)
        let width = view.bounds.width - TerminalContainer.scrollerWidth
        let col = min(cols - 1, max(0, Int(p.x / max(width, 1) * CGFloat(cols))))
        let row = min(rows - 1, max(0, Int((view.bounds.height - p.y) / max(view.bounds.height, 1) * CGFloat(rows))))
        for _ in 0..<min(abs(lines), 12) {
            if mouse {
                let flags = t.encodeButton(button: up ? 4 : 5, release: false,
                                           shift: e.modifierFlags.contains(.shift),
                                           meta: e.modifierFlags.contains(.option),
                                           control: e.modifierFlags.contains(.control))
                t.sendEvent(buttonFlags: flags, x: col, y: row)
            } else {
                view.send(txt: t.applicationCursor ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B"))
            }
        }
        return true
    }
}

/// Selecting text in an agent terminal. herdr's attach turns mouse reporting
/// on, so a drag goes to the program: right inside an agent that selects for
/// itself, useless in the plain shell left after it exits. So with no agent in
/// the pane the mouse stays here (drag selects, ⌘C copies), and Shift-drag
/// selects anywhere, as in Ghostty.
@MainActor
enum TerminalSelect {
    private static var monitor: Any?
    /// Per terminal: whether its pane has an agent to give the mouse to.
    static var toAgent: [ObjectIdentifier: Bool] = [:]
    /// The terminal a Shift-drag is selecting in, until the button comes up.
    private static var holding: LocalProcessTerminalView?

    static func set(_ view: LocalProcessTerminalView, agent: Bool) {
        toAgent[ObjectIdentifier(view)] = agent
        if holding !== view { view.allowMouseReporting = agent }
    }

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            if e.type == .leftMouseUp {
                // Back to the agent once the terminal has seen the release.
                if holding != nil { DispatchQueue.main.async { release() } }
                return e
            }
            guard e.modifierFlags.contains(.shift),
                  let view = TerminalScroll.views.values.first(where: { $0.window === e.window && $0.window != nil }),
                  view.bounds.contains(view.convert(e.locationInWindow, from: nil)) else { return e }
            holding = view
            view.allowMouseReporting = false
            return e
        }
    }

    private static func release() {
        guard let v = holding else { return }
        holding = nil
        v.allowMouseReporting = toAgent[ObjectIdentifier(v)] ?? true
    }
}

struct AgentPopout: View {
    @ObservedObject var session: TerminalSession
    /// The window's title-bar height: the header shares that row with the traffic lights.
    var titlebar: CGFloat = 28
    @ObservedObject var store = Store.shared
    @ObservedObject var themes = Themes.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var agent: AgentInfo? { store.state.agents.first { $0.pane == session.pane } }
    private var theme: TermTheme { themes.current }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                TerminalHost(session: session)
                    .padding(.top, 4)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.bottom, 6)
                if session.ended {
                    VStack(spacing: 10) {
                        Text("Detached from \(agent?.kind ?? "the agent")").font(Type.title)
                        Button("Reattach") { session.attach() }.buttonStyle(.glassProminent)
                    }
                    .padding(18)
                    .raySurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .transition(.surface(reduce: reduce))
                }
            }
        }
        .background(Color(hex: theme.background))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { session.attach() }
        // An agent takes the mouse; the shell it leaves behind gives it back.
        .onChange(of: agent == nil, initial: true) { _, gone in TerminalSelect.set(session.view, agent: !gone) }
        .onDisappear { session.detach() }
    }

    /// One line, exactly as tall as the title bar, so it sits level with the
    /// traffic lights.
    private var header: some View {
        HStack(spacing: 8) {
            AgentGlyph(status: agent?.status ?? "unknown", size: 10, pulse: store.pulses[session.pane] ?? 0)
            Text(agent.map { "\($0.kind) · \($0.folder)" } ?? session.pane)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(agent.map { [$0.status, $0.title].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "no agent")
                .font(.system(size: 12))
                .opacity(0.55)
                .lineLimit(1)
                .contentTransition(.interpolate)
            Spacer(minLength: 8)
            OpenInButton(agent: agent, pane: session.pane, tint: Color(hex: theme.foreground).opacity(0.6))
            CloseSessionButton(pane: session.pane, tint: Color(hex: theme.foreground).opacity(0.6))
        }
        .foregroundStyle(Color(hex: theme.foreground))
        .padding(.leading, 78)
        .padding(.trailing, 10)
        .frame(height: titlebar)
    }
}
