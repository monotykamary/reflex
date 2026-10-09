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
        apply(Themes.shared.current, size: Themes.shared.fontSize)
        Themes.shared.$current.combineLatest(Themes.shared.$fontSize)
            .sink { [weak self] t, s in self?.apply(t, size: s) }
            .store(in: &bag)
    }

    func apply(_ t: TermTheme, size: Double) {
        view.installColors(t.palette.map { hex in
            let c = NSColor(hex: hex).usingColorSpace(.sRGB) ?? .black
            return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535),
                                   blue: UInt16(c.blueComponent * 65535))
        })
        view.nativeBackgroundColor = NSColor(hex: t.background)
        view.nativeForegroundColor = NSColor(hex: t.foreground)
        view.caretColor = NSColor(hex: t.cursor)
        view.selectedTextBackgroundColor = NSColor(hex: t.selection)
        view.font = NSFont(name: "SF Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        view.needsDisplay = true
    }

    /// Attach, retrying quietly: Herdr refuses an attach while a read is in flight.
    func attach() {
        ended = false
        let script = """
        err=$(mktemp -t reflex-attach)
        for i in 1 2 3 4 5 6 7 8 9 10; do
          herdr agent attach "$1" 2>"$err" && { rm -f "$err"; exit 0; }
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
        if attached { view.terminate() }
        attached = false
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

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> LocalProcessTerminalView { session.view }
    func updateNSView(_ v: LocalProcessTerminalView, context: Context) {}
}

struct AgentPopout: View {
    @ObservedObject var session: TerminalSession
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
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                if session.ended {
                    VStack(spacing: 10) {
                        Text("Detached from \(agent?.kind ?? "the agent")").font(Type.title)
                        Button("Reattach") { session.attach() }.buttonStyle(.glassProminent)
                    }
                    .padding(18)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .transition(.surface(reduce: reduce))
                }
            }
        }
        .background(Color(hex: theme.background))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { session.attach() }
        .onDisappear { session.detach() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Bead(status: agent?.status ?? "unknown", size: 8, pulse: store.pulses[session.pane] ?? 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.map { "\($0.kind) · \($0.folder)" } ?? session.pane).font(Type.title).lineLimit(1)
                Text(agent.map { [$0.status, $0.title].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "no agent")
                    .font(Type.meta).opacity(0.6).lineLimit(1)
                    .contentTransition(.interpolate)
            }
            Spacer()
            Menu {
                ForEach(themes.names, id: \.self) { n in
                    Button { themes.select(n) } label: {
                        if n == theme.name { Label(n, systemImage: "checkmark") } else { Text(n) }
                    }
                }
            } label: {
                Label(theme.name, systemImage: "paintpalette")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.small)
            .fixedSize()
            Button("Focus in herdr", systemImage: "rectangle.portrait.and.arrow.right") {
                Task { await Client.local.focus(session.pane) }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .foregroundStyle(Color(hex: theme.foreground))
        .padding(.leading, 84)
        .padding(.trailing, 12)
        .frame(height: 52)
    }
}
