import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI

// Settings, laid out like System Settings: a searchable sidebar of panes with
// coloured icon tiles, and grouped rows — title and explanation on the left,
// the control on the right — so nothing is ever cut off.

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, rail, terminal, routing, projects, phone, setup, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .rail: return "Edge & Rail"
        case .terminal: return "Terminal"
        case .routing: return "Routing"
        case .projects: return "Projects"
        case .phone: return "Phone"
        case .setup: return "Setup"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .rail: return "sidebar.right"
        case .terminal: return "terminal.fill"
        case .routing: return "arrow.triangle.branch"
        case .projects: return "folder.fill"
        case .phone: return "iphone"
        case .setup: return "checklist"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(white: 0.45)
        case .rail: return Tone.working
        case .terminal: return Color(white: 0.16)
        case .routing: return Tone.route
        case .projects: return Color(red: 0.2, green: 0.6, blue: 0.95)
        case .phone: return Tone.done
        case .setup: return Tone.blocked
        case .about: return Color(white: 0.45)
        }
    }

    var blurb: String {
        switch self {
        case .general: return "How Reflex starts, where it shows up, and the agent new sessions use."
        case .rail: return "The tab and rail at the right edge of your screen."
        case .terminal: return "Font and colours for agent terminals."
        case .routing: return "Jev decides where each request goes. Pick its provider and how sure it must be."
        case .projects: return "The folders Reflex can start new sessions in."
        case .phone: return "Answer your agents from your phone."
        case .setup: return "Everything Reflex needs, checked live."
        case .about: return "Reflex, herdr and Jev."
        }
    }

    /// Words the sidebar search matches besides the title.
    var keywords: String {
        switch self {
        case .general: return "login startup dock cmd tab hotkey option double undo agent harness claude codex pi daemon reflexd restart log"
        case .rail: return "edge tab rail hover delay rest questions surface visible sliver"
        case .terminal: return "font geist mono size theme colour color tokyo night ghostty"
        case .routing: return "jev provider api key keychain credential confidence threshold typesafe openrouter vercel test"
        case .projects: return "folders roots repositories index herdr session"
        case .phone: return "remote qr tailscale network link token"
        case .setup: return "onboarding install herdr integrations jev accessibility welcome tour guide"
        case .about: return "version"
        }
    }
}

/// Which pane is showing, with back/forward history like System Settings.
@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var pane: SettingsPane? = SettingsPane(rawValue: ProcessInfo.processInfo.environment["REFLEX_SETTINGS_TAB"] ?? "") ?? .general {
        didSet {
            guard !travelling, let old = oldValue, old != pane else { return }
            back.append(old)
            forward.removeAll()
        }
    }
    @Published private(set) var back: [SettingsPane] = []
    @Published private(set) var forward: [SettingsPane] = []
    private var travelling = false

    func goBack() { travel(from: &back, to: &forward) }
    func goForward() { travel(from: &forward, to: &back) }

    private func travel(from: inout [SettingsPane], to: inout [SettingsPane]) {
        guard let p = from.popLast() else { return }
        if let cur = pane { to.append(cur) }
        travelling = true
        pane = p
        travelling = false
    }
}

struct SettingsView: View {
    @ObservedObject var nav = SettingsNav.shared
    @ObservedObject var daemon = Daemon.shared
    @ObservedObject var store = Store.shared
    @State private var query = ""

    private var panes: [SettingsPane] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter {
            $0.title.lowercased().contains(q) || $0.keywords.contains(q) || $0.blurb.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.pane) {
                identity
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                Section {
                    ForEach(panes.filter { $0 != .setup && $0 != .about }) { row($0) }
                }
                Section {
                    ForEach(panes.filter { $0 == .setup || $0 == .about }) { row($0) }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
            // The sidebar's blur with Raycast's 40% veil, like every Reflex surface.
            .background {
                SurfaceVeil().ignoresSafeArea()
            }
        } detail: {
            Group {
                switch nav.pane ?? .general {
                case .general: GeneralPane()
                case .rail: RailPane()
                case .terminal: TerminalPane()
                case .routing: RoutingPane()
                case .projects: ProjectsPane()
                case .phone: PhonePane()
                case .setup: SetupPane()
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(nav.pane?.title ?? "Settings")
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { nav.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(nav.back.isEmpty)
                        .help("Back")
                    Button { nav.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(nav.forward.isEmpty)
                        .help("Forward")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    private func row(_ p: SettingsPane) -> some View {
        Label {
            Text(p.title)
        } icon: {
            IconTile(symbol: p.symbol, tint: p.tint, size: 22)
        }
        .badge(p == .setup ? SetupState.shared.missing : 0)
        .tag(p)
    }

    /// The "account" row: Reflex itself, and whether its daemon is up.
    private var identity: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reflex").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(daemon.running ? Tone.done : Tone.blocked).frame(width: 6, height: 6)
                    Text(daemon.running ? agentsLine : "reflexd stopped")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var agentsLine: String {
        let n = store.state.agents.count
        return n == 1 ? "1 agent in herdr" : "\(n) agents in herdr"
    }
}

/// System Settings' coloured rounded-square icon.
struct IconTile: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// The header card at the top of each pane.
private struct PaneHeader: View {
    var pane: SettingsPane
    var body: some View {
        VStack(spacing: 8) {
            IconTile(symbol: pane.symbol, tint: pane.tint, size: 56)
            Text(pane.title).font(.system(size: 22, weight: .bold))
            Text(pane.blurb).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

/// A row's title with an optional explanation under it.
private struct RowLabel: View {
    var title: String
    var detail: String?
    init(_ title: String, _ detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var daemon = Daemon.shared
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section { PaneHeader(pane: .general) }
            Section {
                Toggle(isOn: Binding(get: { login }, set: setLogin)) {
                    RowLabel("Open at login", loginError)
                }
                Picker(selection: $s.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                } label: {
                    RowLabel("Appearance", "Reflex's surfaces follow macOS, or stay light or dark.")
                }
                Toggle(isOn: $s.showInDock) {
                    RowLabel("Show in the Dock and ⌘Tab", "When off, Reflex lives in the menu bar and at the edge.")
                }
                LabeledContent {
                    HStack(spacing: 4) { KeyCap(key: "⌥"); KeyCap(key: "⌥") }
                } label: {
                    RowLabel("Ask", DoubleOption.trusted ? "Double-tap Option anywhere." : "Needs Accessibility — see Setup.")
                }
            }
            Section("New sessions") {
                Picker(selection: $s.harness) {
                    ForEach(Onboarding.harnesses, id: \.self) { Text($0) }
                } label: {
                    RowLabel("Default agent", "Used when Jev starts a session in a folder.")
                }
                LabeledContent {
                    Stepper(value: $s.undoMs, in: 0...10000, step: 500) {
                        Text(String(format: "%.1f s", Double(s.undoMs) / 1000)).monospacedDigit()
                    }
                } label: {
                    RowLabel("Undo window", "How long you have to take a request back before it is sent.")
                }
            }
            Section("reflexd") {
                LabeledContent {
                    HStack {
                        Button("Open Log") { NSWorkspace.shared.open(Daemon.logURL) }
                        Button("Restart") { daemon.restart() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(daemon.running ? Tone.done : Tone.blocked).frame(width: 7, height: 7)
                        RowLabel(daemon.running ? "Running" : "Stopped", daemon.lastError)
                    }
                }
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        login = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Edge & Rail

private struct RailPane: View {
    @ObservedObject var s = Settings.shared
    var body: some View {
        Form {
            Section { PaneHeader(pane: .rail) }
            Section {
                Toggle(isOn: $s.showStrip) {
                    RowLabel("Show the tab while agents are active", "A small tab at the edge: a ring per working agent, amber when one waits, green when done.")
                }
                Toggle(isOn: $s.surfaceQuestions) {
                    RowLabel("Surface new questions", "When an agent asks something, the rail opens by itself for a few seconds.")
                }
                Toggle(isOn: $s.railAlways) {
                    RowLabel("Keep the rail open", "Otherwise it opens when you hover the tab or rest on the edge.")
                }
            }
            Section {
                Picker(selection: $s.edgeDelay) {
                    Text("Quick (0.3 s)").tag(0.3)
                    Text("Normal (0.5 s)").tag(0.5)
                    Text("Relaxed (0.8 s)").tag(0.8)
                } label: {
                    RowLabel("Rest on the edge", "How long the pointer rests on an empty right edge before the rail opens.")
                }
                .disabled(s.railAlways)
            }
        }
    }
}

// MARK: - Terminal

private struct TerminalPane: View {
    @ObservedObject var themes = Themes.shared
    @State private var query = ""

    private var names: [String] {
        query.isEmpty ? themes.names : themes.names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Form {
            Section { TerminalPreview(theme: themes.current, family: themes.fontFamily, size: themes.fontSize) }
            Section {
                Picker(selection: $themes.fontFamily) {
                    ForEach(Themes.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                } label: {
                    RowLabel("Font", themes.fontFamily == Themes.defaultFamily ? "The default." : "Default: \(Themes.defaultFamily).")
                }
                LabeledContent {
                    Stepper(value: $themes.fontSize, in: 9...22, step: 0.5) {
                        Text(String(format: "%.1f pt", themes.fontSize)).monospacedDigit()
                    }
                } label: {
                    RowLabel("Size")
                }
            }
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("", text: $query, prompt: Text("Search \(themes.names.count) themes"))
                        .textFieldStyle(.plain)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(names, id: \.self) { name in
                                ThemeRow(name: name, selected: name == themes.current.name)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(name == themes.current.name ? Color.accentColor.opacity(0.14) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .contentShape(Rectangle())
                                    .onTapGesture { themes.select(name) }
                                    .id(name)
                            }
                        }
                    }
                    .frame(height: 300)
                    .scrollIndicators(.never)
                    .onAppear { proxy.scrollTo(themes.current.name, anchor: .center) }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Every Ghostty theme when Ghostty is installed. Add more in ~/.config/ghostty/themes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A few lines of a fake agent session, in the chosen font and colours.
private struct TerminalPreview: View {
    var theme: TermTheme
    var family: String
    var size: Double

    private func c(_ i: Int) -> Color { Color(hex: theme.palette[i]) }

    var body: some View {
        let font = Font(Themes.font(family, size: size))
        VStack(alignment: .leading, spacing: 3) {
            (Text("~/VCS/jev-fabric ").foregroundColor(c(4)) + Text("main ").foregroundColor(c(5)) + Text("❯ ").foregroundColor(c(2)) + Text("claude"))
            (Text("● ").foregroundColor(c(2)) + Text("Read ").bold() + Text("src/follow.bend").foregroundColor(c(6)))
            (Text("  + ").foregroundColor(c(2)) + Text("fuel loop bounded at 64").foregroundColor(c(2)))
            (Text("  - ").foregroundColor(c(1)) + Text("unbounded retry").foregroundColor(c(1)))
            (Text("? ").foregroundColor(c(3)) + Text("Run the tests now? ") + Text("1 Yes  2 No").foregroundColor(c(8)))
        }
        .font(font)
        .foregroundColor(Color(hex: theme.foreground))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(hex: theme.background), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

private struct ThemeRow: View {
    var name: String
    var selected: Bool
    @State private var theme: TermTheme?

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: theme?.background ?? "#000000"))
                HStack(spacing: 2) {
                    Text("Aa").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(hex: theme?.foreground ?? "#ffffff"))
                    ForEach(Array((theme?.palette ?? []).enumerated()).filter { [1, 2, 3, 4, 5, 6].contains($0.offset) }, id: \.offset) { _, c in
                        Circle().fill(Color(hex: c)).frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(width: 92, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            Text(name)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .task(id: name) { theme = Themes.load(name) }
    }
}

// MARK: - Routing

private struct RoutingPane: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var onboarding = Onboarding.shared
    @State private var key = ""
    @State private var hasKey = Settings.jevKey != nil

    var body: some View {
        Form {
            Section { PaneHeader(pane: .routing) }
                .onAppear { if onboarding.ping == .idle { onboarding.test() } }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(pingText).font(.system(size: 12)).foregroundStyle(pingColor).lineLimit(1)
                        Button(onboarding.ping == .testing ? "Testing…" : "Test") { onboarding.test() }
                            .disabled(onboarding.ping == .testing)
                    }
                } label: {
                    RowLabel("Jev", "Asks one typed question per request; no chat model rewrites your words.")
                }
                Picker(selection: $s.jevProvider) {
                    ForEach(["typesafe", "openrouter", "vercel"], id: \.self) { Text($0) }
                } label: {
                    RowLabel("Provider")
                }
            }
            Section("Credentials") {
                LabeledContent {
                    HStack {
                        SecureField("", text: $key, prompt: Text(hasKey ? "Saved in Keychain" : "Paste a key"))
                            .frame(maxWidth: 220)
                            .onSubmit(save)
                        Button("Save", action: save).disabled(key.isEmpty)
                    }
                } label: {
                    RowLabel("API key", "Stored in your Keychain.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    RowLabel("Credential command", "Instead of a key: a JSON argv that prints one. Takes precedence over the key.")
                    TextField("", text: $s.jevCredentialCommand, prompt: Text("[\"op\", \"read\", \"op://…\"]"), axis: .vertical)
                        .font(.system(size: 11.5, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                }
                if let pi = Settings.piCredentialCommand, s.jevCredentialCommand != pi {
                    LabeledContent {
                        Button("Use It") { onboarding.usePiKey() }
                    } label: {
                        RowLabel("pi has a TypeSafe key", "Read it from pi when needed, without copying it.")
                    }
                }
            }
            Section {
                LabeledContent {
                    HStack {
                        Slider(value: Binding(get: { Double(s.threshold) }, set: { s.threshold = Int($0) }), in: 3000...9500, step: 250)
                            .frame(width: 180)
                        Text("\(s.threshold / 100)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    RowLabel("Confidence to act", "Below this, Reflex asks you to pick 1, 2 or 3 instead of routing on its own.")
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Apply & Restart reflexd") { Daemon.shared.restart(); onboarding.test() }
                }
            }
        }
    }

    private func save() {
        onboarding.saveKey(key)
        key = ""
        hasKey = Settings.jevKey != nil
    }

    private var pingText: String {
        switch onboarding.ping {
        case .idle: return "not tested"
        case .testing: return "asking…"
        case .ok(let ms): return "answering · \(ms) ms"
        case .failed(let e): return e
        }
    }

    private var pingColor: Color {
        switch onboarding.ping {
        case .ok: return Tone.done
        case .failed: return Tone.blocked
        default: return .secondary
        }
    }
}

// MARK: - Projects

private struct ProjectsPane: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var store = Store.shared

    private var roots: [String] { s.roots.split(separator: ":").map(String.init) }

    var body: some View {
        Form {
            Section { PaneHeader(pane: .projects) }
            Section {
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Color(red: 0.2, green: 0.6, blue: 0.95))
                        Text(root.abbreviatingHome)
                        Spacer()
                        Button {
                            Onboarding.shared.setRoots(roots.filter { $0 != root })
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                }
                HStack {
                    Button("Add Folder…") { Onboarding.shared.addRoot() }
                    Spacer()
                    Text(store.state.folders == 0 ? "indexing…" : "\(store.state.folders) repositories")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("Reflex indexes the repositories under these folders — names, descriptions, recent commits — so Jev can start a session in the right one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Rebuild") { Task { await Client.local.reindex() } }
                } label: {
                    RowLabel("Folder index", "Rebuilt on its own every few minutes.")
                }
                LabeledContent {
                    TextField("", text: $s.herdrSession, prompt: Text("default"))
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                } label: {
                    RowLabel("herdr session", "Leave empty for herdr's default session. Restart reflexd after changing.")
                }
            }
        }
    }
}

// MARK: - Phone

private struct PhonePane: View {
    @ObservedObject var s = Settings.shared
    var body: some View {
        Form {
            Section { PaneHeader(pane: .phone) }
            Section {
                Toggle(isOn: Binding(get: { s.remote }, set: { s.remote = $0; Daemon.shared.restart() })) {
                    RowLabel("Allow the phone remote", s.remote ? "reflexd listens on your network." : "Off: reflexd only listens on this Mac.")
                }
            }
            if s.remote {
                let url = Remote.url(port: s.port, token: Settings.token)
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        if let img = Remote.qr(url) {
                            Image(nsImage: img).interpolation(.none).resizable().frame(width: 150, height: 150)
                                .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan with your phone's camera, then add the page to your home screen.")
                            Text(url).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                            Label(Remote.preferredIsTailscale ? "Over Tailscale: encrypted end to end." : "No Tailscale address: this LAN link is not encrypted.",
                                  systemImage: Remote.preferredIsTailscale ? "lock.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Remote.preferredIsTailscale ? Color.secondary : Tone.blocked)
                        }
                    }
                    LabeledContent {
                        Button("New Link") { Settings.rotateToken(); Daemon.shared.restart() }
                    } label: {
                        RowLabel("Revoke", "Makes a new link; the old one stops working.")
                    }
                }
            }
        }
    }
}

// MARK: - Setup (what onboarding checks, kept here for later)

/// Live checks shared by the Setup pane and the sidebar badge.
@MainActor
final class SetupState: ObservableObject {
    static let shared = SetupState()
    @Published var missing = 0
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    func update() {
        let o = Onboarding.shared
        o.refresh()
        let ok = [o.herdrInstalled, o.herdrRunning, o.integrations, o.jevInstalled, o.trusted]
        missing = ok.filter { !$0 }.count
    }
}

private struct SetupPane: View {
    @ObservedObject var o = Onboarding.shared
    @ObservedObject var store = Store.shared
    var openTour: () -> Void = { AppDelegate.current?.showOnboarding() }

    var body: some View {
        Form {
            Section { PaneHeader(pane: .setup) }
            Section("herdr") {
                CheckRow(ok: o.herdrInstalled, title: "herdr installed", detail: o.herdrInstalled ? nil : "brew install herdr") {
                    Button("Copy Command") { o.copy("brew install herdr") }
                }
                CheckRow(ok: o.herdrRunning, title: "herdr running",
                         detail: o.herdrRunning ? (store.state.agents.count == 1 ? "1 agent" : "\(store.state.agents.count) agents") : "Run `herdr` in a terminal.") {
                    Button("Copy Command") { o.copy("herdr") }
                }
                CheckRow(ok: o.integrations, title: "Agent integrations", detail: "Exact session ids, so side questions can fork the right session.") {
                    Button(o.working == "integrations" ? "Installing…" : "Install") {
                        o.run("integrations", "herdr integration install claude; herdr integration install pi")
                    }
                    .disabled(o.working != nil)
                }
            }
            Section("Jev") {
                CheckRow(ok: o.jevInstalled, title: "jev-fabric installed", detail: o.jevInstalled ? nil : "One line in a terminal.") {
                    Button("Copy Command") { o.copy("curl -fsSL https://raw.githubusercontent.com/fabric-runtime/jev-fabric/main/install.sh | sh") }
                }
                CheckRow(ok: pingOK, title: "Jev answering", detail: pingDetail, showAccessory: true) {
                    Button(o.ping == .testing ? "Testing…" : "Test") { o.test() }
                }
            }
            Section("Keys") {
                CheckRow(ok: o.trusted, title: "Accessibility", detail: o.trusted ? "⌥⌥ works in every app." : "Lets Reflex hear ⌥⌥ in other apps.") {
                    Button("Allow…") { AccessGuide.shared.start() }
                }
            }
            Section {
                LabeledContent {
                    Button("Show Welcome…", action: openTour)
                } label: {
                    RowLabel("Welcome tour", "The first-run walkthrough: try a request, the double tap, and the edge.")
                }
            }
        }
        .onAppear { SetupState.shared.update(); if o.ping == .idle { o.test() } }
    }

    private var pingOK: Bool { if case .ok = o.ping { return true } else { return false } }

    private var pingDetail: String {
        switch o.ping {
        case .idle: return "Not tested yet."
        case .testing: return "Asking Jev…"
        case .ok(let ms): return "Answered in \(ms) ms."
        case .failed(let e): return e
        }
    }
}

private struct CheckRow<Accessory: View>: View {
    var ok: Bool
    var title: String
    var detail: String?
    var showAccessory = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        LabeledContent {
            if !ok || showAccessory { accessory }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ok ? Tone.done : Tone.blocked)
                    .contentTransition(.symbolEffect(.replace))
                RowLabel(title, detail)
            }
        }
        .animation(Motion.enter, value: ok)
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                    Text("Reflex").font(.system(size: 22, weight: .bold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("One reflex to every coding agent in herdr. Routing by Jev, decisions in reflexd — written in Bend, with its laws proved.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            Section {
                LabeledContent("Daemon log") { Button("Open") { NSWorkspace.shared.open(Daemon.logURL) } }
                LabeledContent("Support folder") { Button("Show in Finder") { NSWorkspace.shared.open(Settings.supportDir) } }
            }
        }
    }
}

// MARK: - Phone remote helpers

enum Remote {
    /// IPv4 addresses of this Mac, Tailscale (100.64.0.0/10) first.
    static var addresses: [String] {
        var out: [String] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return [] }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let i = p {
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") { out.append(ip) }
            }
            p = i.pointee.ifa_next
        }
        return out.sorted { isTailscale($0) && !isTailscale($1) }
    }

    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static var preferredIsTailscale: Bool { addresses.first.map(isTailscale) ?? false }

    static func url(port: Int, token: String) -> String {
        "http://\(addresses.first ?? "127.0.0.1"):\(port)/?t=\(token)"
    }

    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let img = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: img)
        let ns = NSImage(size: rep.size)
        ns.addRepresentation(rep)
        return ns
    }
}
