import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI

// Settings, laid out like System Settings: a searchable sidebar of panes with
// coloured icon tiles, and grouped rows — title and explanation on the left,
// the control on the right — so nothing is ever cut off.

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, rail, terminal, routing, projects, machines, phone, setup, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .rail: return "Edge & Rail"
        case .terminal: return "Terminal"
        case .routing: return "Routing"
        case .projects: return "Projects"
        case .machines: return "Machines"
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
        case .machines: return "desktopcomputer"
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
        case .machines: return Tone.remote
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
        case .routing: return "Jev decides where each request goes. Pick its provider; it learns from your choices."
        case .projects: return "The folders Reflex can start new sessions in."
        case .machines: return "Your other Macs, from herdr's saved machines: their agents show up here with this Mac's."
        case .phone: return "Answer your agents from your phone."
        case .setup: return "Everything Reflex needs, checked live."
        case .about: return "Reflex, herdr and Jev."
        }
    }

    /// Words the sidebar search matches besides the title.
    var keywords: String {
        switch self {
        case .general: return "login startup dock cmd tab hotkey option double agent harness claude codex pi daemon reflexd restart log appearance light dark keep awake caffeinate sleep battery display"
        case .rail: return "edge tab rail hover delay rest questions surface visible sliver menu bar menubar status icon dock"
        case .terminal: return "font geist mono size theme colour color tokyo night ghostty"
        case .routing: return "jev provider api key keychain credential typesafe openrouter vercel test memory forget"
        case .projects: return "folders roots repositories index herdr session new project keyword"
        case .machines: return "remote machines ssh tunnel herdr saved machine other mac work laptop tailscale"
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
                case .machines: MachinesPane()
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

/// Keep awake: off, while agents work, or always; a battery floor; the display.
private struct KeepAwakeSection: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var awake = KeepAwake.shared

    var body: some View {
        Section {
            Picker(selection: $s.awakeMode) {
                Text("Off").tag("off")
                Text("While agents work").tag("agents")
                Text("Always").tag("always")
            } label: {
                RowLabel("Keep the Mac awake", s.awakeMode == "agents"
                         ? "So an agent working through the night isn't stopped by sleep. Lets go a minute after the last one finishes."
                         : (s.awakeMode == "always" ? "While Reflex is running." : "macOS sleeps as usual."))
            }
            if s.awakeMode != "off" {
                Picker(selection: $s.awakeBattery) {
                    Text("Never").tag(0)
                    ForEach([10, 15, 20, 30, 50], id: \.self) { Text("At \($0)%").tag($0) }
                } label: {
                    RowLabel("On battery, let it sleep", "Unplugged and at or below this charge, Reflex stops keeping it awake.")
                }
                Toggle(isOn: $s.awakeDisplay) {
                    RowLabel("Keep the display on too", "Off: the screen may dim and lock; the Mac and your agents keep running.")
                }
            }
        } header: {
            Text("Keep awake")
        } footer: {
            if s.awakeMode != "off" {
                HStack(spacing: 6) {
                    Image(systemName: awake.holding ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(awake.holding ? Tone.blocked : Color.secondary)
                    Text(awake.holding ? "Awake — \(awake.reason.lowercasedFirst)" : (awake.reason.isEmpty ? "Not holding: no agent is working." : awake.reason))
                        .font(Type.meta).foregroundStyle(.secondary)
                }
                .animation(Motion.micro, value: awake.holding)
            }
        }
    }
}

private extension String {
    var lowercasedFirst: String { isEmpty ? self : prefix(1).lowercased() + dropFirst() }
}

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
                    RowLabel("Show in the Dock and ⌘Tab", s.menuBar ? "Off while the rail lives in the menu bar (see Rail), except while a terminal window is open."
                        : "When off, Reflex lives in the menu bar and at the edge, and in the Dock only while a terminal window is open.")
                }
                .disabled(s.menuBar)
                LabeledContent {
                    HStack(spacing: 4) { KeyCap(key: "⌥"); KeyCap(key: "⌥") }
                } label: {
                    RowLabel("Ask", DoubleOption.trusted ? "Double-tap Option anywhere." : "Needs Accessibility — see Setup.")
                }
            }
            KeepAwakeSection()
            Section("New sessions") {
                Picker(selection: $s.harness) {
                    ForEach(Onboarding.harnesses, id: \.self) { Text($0) }
                } label: {
                    RowLabel("Default agent", "Used when Jev starts a session in a folder.")
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
                Picker(selection: $s.menuBar) {
                    Text("Screen edge").tag(false)
                    Text("Menu bar").tag(true)
                } label: {
                    RowLabel("Where the rail lives", s.menuBar
                        ? "Click Reflex's menu bar icon for the waiting question or every agent; right-click for the menu. No edge, no Dock icon."
                        : "At the right edge of the screen. In the menu bar, Reflex also leaves the Dock.")
                }
            }
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
            .disabled(s.menuBar)
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
            .disabled(s.menuBar)
        }
    }
}

// MARK: - Terminal

private struct TerminalPane: View {
    @ObservedObject var themes = Themes.shared
    @State private var query = ""
    @State private var slot: Themes.Slot = Themes.shared.activeSlot
    @State private var listAt: String?

    private func name(_ s: Themes.Slot) -> String { s == .dark ? themes.darkName : themes.lightName }

    /// The slot's themes only: dark ones for Dark, light ones for Light.
    private var names: [String] {
        themes.names.filter { n in
            (query.isEmpty || n.localizedCaseInsensitiveContains(query))
                && (themes.darkness[n].map { $0 == (slot == .dark) } ?? true)
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 0) {
                    SlotCard(slot: .dark, name: themes.darkName, inUse: themes.activeSlot == .dark,
                             editing: slot == .dark, family: themes.fontFamily) { withAnimation(Motion.swap) { slot = .dark } }
                    Button { themes.linked.toggle() } label: {
                        Image(systemName: themes.linked ? "link" : "link.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(themes.linked ? Color.accentColor : .secondary)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(Pressable())
                    .help(themes.linked ? "Paired: picking one picks its sibling" : "Not paired: each slot on its own")
                    SlotCard(slot: .light, name: themes.lightName, inUse: themes.activeSlot == .light,
                             editing: slot == .light, family: themes.fontFamily) { withAnimation(Motion.swap) { slot = .light } }
                }
            }
            Section {
                Picker(selection: $themes.mode) {
                    Text("Follow Reflex").tag(Themes.Mode.follow)
                    Text("Always dark").tag(Themes.Mode.dark)
                    Text("Always light").tag(Themes.Mode.light)
                } label: {
                    RowLabel("Terminal appearance", "Following Reflex, terminals switch with Settings → General → Appearance.")
                }
                Toggle(isOn: $themes.linked) {
                    RowLabel("Keep pairs together", "Picking TokyoNight picks TokyoNight Day, Catppuccin Mocha picks Latte — and back.")
                }
            }
            Section("Start from a pair") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                    ForEach(Themes.starterPairs.filter { themes.names.contains($0.dark) && themes.names.contains($0.light) }) { pair in
                        PairChip(pair: pair, on: themes.darkName == pair.dark && themes.lightName == pair.light) {
                            withAnimation(Motion.swap) { themes.choose(pair) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
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
                    TextField("", text: $query, prompt: Text("Search \(slot == .dark ? "dark" : "light") themes"))
                        .textFieldStyle(.plain)
                }
                // Scrolls itself to the chosen theme, without moving the page.
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(names, id: \.self) { n in
                            ThemeRow(name: n, selected: n == name(slot))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(n == name(slot) ? Color.accentColor.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { withAnimation(Motion.swap) { themes.select(n, for: slot) } }
                                .id(n)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $listAt, anchor: .center)
                .frame(height: 300)
                .scrollIndicators(.never)
                .onAppear { listAt = name(slot) }
                .onChange(of: slot) { _, s in listAt = name(s) }
                HStack {
                    Button("Import Theme…", action: importTheme)
                    Button("Show Themes Folder") {
                        let dir = Settings.supportDir.appendingPathComponent("themes")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    Spacer()
                }
            } header: {
                HStack {
                    Text("Themes")
                    Spacer()
                    Segmented(selection: $slot, options: [("Dark", .dark), ("Light", .light)])
                }
            } footer: {
                Text("Every Ghostty theme when Ghostty is installed, and any Ghostty-format theme you import.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { themes.learnDarkness() }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose Ghostty-format theme files (palette = N=#rrggbb, background, foreground…)."
        guard panel.runModal() == .OK else { return }
        let added = themes.importThemes(panel.urls)
        if let first = added.first, let t = Themes.load(first) {
            slot = t.isDark ? .dark : .light
            themes.select(first, for: slot)
        }
    }
}

/// One slot as a small terminal: its theme, whether it is in use, and
/// whether the list below is choosing for it.
private struct SlotCard: View {
    var slot: Themes.Slot
    var name: String
    var inUse: Bool
    var editing: Bool
    var family: String
    var pick: () -> Void
    @State private var theme: TermTheme?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = theme {
                TerminalPreview(theme: t, family: family, size: 10, compact: true)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary).frame(height: 92)
            }
            HStack(spacing: 6) {
                Image(systemName: slot == .dark ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .contentTransition(.interpolate)
                Spacer(minLength: 4)
                if inUse {
                    Text("In use")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .transition(.opacity)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(editing ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: editing ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .task(id: name) { theme = Themes.load(name) }
        .animation(Motion.swap, value: inUse)
    }
}

/// A starter pair: both backgrounds side by side, and the family's name.
private struct PairChip: View {
    var pair: Themes.Pair
    var on: Bool
    var pick: () -> Void
    @State private var dark: TermTheme?
    @State private var light: TermTheme?

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    swatch(dark)
                    swatch(light)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                Text(pair.name).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .task {
            dark = Themes.load(pair.dark)
            light = Themes.load(pair.light)
        }
    }

    private func swatch(_ t: TermTheme?) -> some View {
        ZStack {
            Color(hex: t?.background ?? "#808080")
            HStack(spacing: 2) {
                ForEach([1, 2, 4], id: \.self) { i in
                    Circle().fill(Color(hex: t?.palette[i] ?? "#808080")).frame(width: 4, height: 4)
                }
            }
        }
        .frame(width: 26, height: 22)
    }
}

/// A few lines of a fake agent session, in the chosen font and colours.
private struct TerminalPreview: View {
    var theme: TermTheme
    var family: String
    var size: Double
    var compact = false

    private func c(_ i: Int) -> Color { Color(hex: theme.palette[i]) }

    var body: some View {
        let font = Font(Themes.font(family, size: size))
        VStack(alignment: .leading, spacing: 3) {
            (Text("~/VCS/jev-fabric ").foregroundColor(c(4)) + Text("main ").foregroundColor(c(5)) + Text("❯ ").foregroundColor(c(2)) + Text("claude"))
            (Text("● ").foregroundColor(c(2)) + Text("Read ").bold() + Text("src/follow.bend").foregroundColor(c(6)))
            (Text("  + ").foregroundColor(c(2)) + Text("fuel loop bounded at 64").foregroundColor(c(2)))
            if !compact {
                (Text("  - ").foregroundColor(c(1)) + Text("unbounded retry").foregroundColor(c(1)))
            }
            (Text("? ").foregroundColor(c(3)) + Text("Run the tests now? ") + Text("1 Yes  2 No").foregroundColor(c(8)))
        }
        .font(font)
        .foregroundColor(Color(hex: theme.foreground))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 10 : 14)
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
    @State private var corrections = 0

    var body: some View {
        Form {
            Section { PaneHeader(pane: .routing) }
                .onAppear {
                    if onboarding.ping == .idle { onboarding.test() }
                    onboarding.refresh()
                    onboarding.askLatest()
                }
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
                    ForEach(["typesafe", "openrouter", "vercel", "subq"], id: \.self) { Text($0) }
                } label: {
                    RowLabel("Provider")
                }
                // Each provider has its own key; the daemon takes the new one.
                .onChange(of: s.jevProvider) {
                    hasKey = Settings.jevKey != nil
                    onboarding.providerChanged()
                }
                if onboarding.jevTooOld {
                    LabeledContent {
                        Button(onboarding.installLabel(.jev)) { onboarding.install(.jev) }
                            .disabled(onboarding.working != nil)
                    } label: {
                        RowLabel("jev-fabric", onboarding.jevDetail)
                    }
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
                    // Code reads from the left: a text editor, not a Form text
                    // field (which a grouped Form aligns to the right).
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $s.jevCredentialCommand)
                            .font(.system(size: 11.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 4).padding(.vertical, 6)
                        if s.jevCredentialCommand.isEmpty {
                            Text("[\"op\", \"read\", \"op://…\"]")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 62)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
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
                HStack {
                    Spacer()
                    Button("Apply & Restart reflexd") { Daemon.shared.restart(); onboarding.test() }
                }
            }
            Section {
                LabeledContent {
                    Button("Forget") { Memory.shared.forget(); corrections = 0 }
                        .disabled(corrections == 0)
                } label: {
                    RowLabel("Memory",
                             corrections == 0
                                ? "Where your recent requests went, so follow-ups like \u{201C}also add tests there\u{201D} land in the same session. When you pick something other than Jev\u{2019}s suggestion, Jev remembers it for similar requests. Kept on this Mac."
                                : "Jev has learned from \(corrections) of your corrections, and knows where your recent requests went. Kept on this Mac.")
                }
            }
        }
        .onAppear { corrections = Memory.shared.corrections }
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
                Text("Reflex indexes the repositories under these folders — names, descriptions, recent commits, when you last worked in them — so Jev can start a session in the right one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !s.extraFolders.isEmpty {
                Section {
                    ForEach(s.extraFolders, id: \.self) { f in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(f.abbreviatingHome)
                            Spacer()
                            Button {
                                s.extraFolders.removeAll { $0 == f }
                                Task { await Client.local.reindex() }
                            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                    }
                } header: {
                    Text("Added from the Ask bar")
                } footer: {
                    Text("Single folders you chose with “Choose folder…” that sit outside the folders above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    TextField("", text: $s.newKeyword, prompt: Text("new project"))
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                } label: {
                    RowLabel("New project keyword", "Say this in a request to start in a new folder. Otherwise Reflex picks an existing one — or suggests a new folder only when nothing fits, and asks you to name it.")
                }
                Picker(selection: $s.newRoot) {
                    Text("First folder above").tag("")
                    ForEach(roots, id: \.self) { Text($0.abbreviatingHome).tag($0) }
                } label: {
                    RowLabel("New projects go in")
                }
            } header: {
                Text("New projects")
            }
            Section {
                LabeledContent {
                    Button("Rebuild") { Task { await Client.local.reindex() } }
                } label: {
                    RowLabel("Folder index", "Rebuilt on its own every few minutes.")
                }
                Picker(selection: Binding(get: { s.backend }, set: { s.backend = $0; Daemon.shared.restart() })) {
                    Text("herdr-core").tag("core")
                    Text("herdr").tag("herdr")
                } label: {
                    RowLabel("New sessions start in", "Agents already running in either stay listed, and you can still answer and open them.")
                }
                LabeledContent {
                    TextField("", text: $s.coreSession, prompt: Text("default"))
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                } label: {
                    RowLabel("herdr-core session", "HC_SESSION: leave empty for the default core. Restart reflexd after changing.")
                }
                Toggle(isOn: $s.startCore) {
                    RowLabel("Start herdr-core when it isn't running", "Its agents keep running whatever happens to Reflex; after a reboot it starts again here.")
                }
                LabeledContent {
                    TextField("", text: $s.herdrSession, prompt: Text("default"))
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                } label: {
                    RowLabel("herdr session", "Leave empty for herdr's default session. Restart reflexd after changing.")
                }
                Toggle(isOn: $s.startHerdr) {
                    RowLabel("Start herdr when it isn't running", "While new sessions start in herdr: after a restart, say, Reflex starts herdr's server in the background, the way herdr itself does.")
                }
            }
        }
    }
}

// MARK: - Machines

private struct MachinesPane: View {
    @ObservedObject var machines = MachinesModel.shared
    @ObservedObject var store = Store.shared

    var body: some View {
        Form {
            Section { PaneHeader(pane: .machines) }
                .onAppear { Machines.shared.refresh() }
            Section {
                if machines.rows.isEmpty {
                    RowLabel(machines.loaded ? "No machines yet" : "Asking herdr…",
                             "Add one below, or in a terminal with `herdr machine add <ssh-host>`.")
                }
                ForEach(machines.rows) { m in
                    MachineRow(machine: m, agents: store.state.agents.filter { $0.machine == m.key }.count)
                }
            } header: {
                Text("From herdr")
            } footer: {
                Text("Reflex keeps one SSH tunnel to each enabled machine, with your own ssh config, keys and agent, and reconnects when it drops. Their agents wear the machine's name (and a \(Image(systemName: "circle.fill")) badge) in the rail, the inbox and the ⌥⌥ bar. `herdr machine disable`, `enable` and `remove` change this list.")
                    .font(Type.meta).foregroundStyle(.secondary)
            }
            CoreMachinesSection()
            Section("Add a Mac") {
                MachineSteps()
                AddMachineView()
            }
        }
    }
}

/// herdr-core's machines: the core reaches them itself, and their terminals
/// join its list (no tunnel of Reflex's). `hc machine rm` removes one.
private struct CoreMachinesSection: View {
    @ObservedObject var store = Store.shared
    @State private var rows: [CoreMachines.Machine] = []
    @State private var loaded = false

    var body: some View {
        Section {
            if rows.isEmpty {
                RowLabel(loaded ? "No machines yet" : "Asking herdr-core…",
                         "Add one below, or in a terminal with `hc machine add <ssh-host>`.")
            }
            ForEach(rows, id: \.name) { m in
                let agents = store.state.agents.filter { $0.machine == m.name }.count
                LabeledContent {
                    if m.state != "connected" {
                        Button("Reconnect") { Task { _ = try? await HerdrCore.call("machine.connect", ["machine": m.name], timeout: 30); await load() } }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: m.state == "connected" ? "checkmark.circle.fill" : m.state == "connecting" ? "arrow.triangle.2.circlepath" : "exclamationmark.circle.fill")
                            .foregroundStyle(m.state == "connected" ? Tone.done : m.state == "connecting" ? Tone.working : Tone.blocked)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) { Text(m.name); MachineChip(machine: m.name) }
                            Text("ssh \(m.target)" + (m.version.isEmpty ? "" : " · hc \(m.version)"))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(Self.state(m, agents: agents)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } header: {
            Text("From herdr-core")
        } footer: {
            Text("herdr-core dials each machine over your ssh and keeps the line up; its agents wear the machine's name in the rail, the inbox and the ⌥⌥ bar.")
                .font(Type.meta).foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func load() async {
        rows = await CoreMachines.list(fresh: 2)
        loaded = true
    }

    private static func state(_ m: CoreMachines.Machine, agents: Int) -> String {
        switch m.state {
        case "connected": return agents == 1 ? "Connected · 1 agent" : "Connected · \(agents) agents"
        case "connecting": return "Connecting…"
        case "needs_login": return "Needs you to sign in: run `hc machine connect \(m.name)` in Terminal."
        case "needs_update": return "Its herdr-core needs updating: run `hc update` there."
        default: return m.why.isEmpty ? m.state : m.why
        }
    }
}

private struct MachineRow: View {
    var machine: MachinesModel.Row
    var agents: Int

    private var state: (symbol: String, tone: Color, text: String) {
        switch machine.link {
        case .connected: return ("checkmark.circle.fill", Tone.done, agents == 1 ? "Connected · 1 agent" : "Connected · \(agents) agents")
        case .connecting: return ("arrow.triangle.2.circlepath", Tone.working, "Connecting…")
        case .off: return ("pause.circle", Color.secondary, "Disabled in herdr")
        case .down(let why): return ("exclamationmark.circle.fill", Tone.blocked, why)
        }
    }

    var body: some View {
        LabeledContent {
            if machine.link != .off {
                Button("Reconnect") { Machines.shared.reconnect(machine.key) }
                    .disabled(machine.link == .connecting)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: state.symbol).foregroundStyle(state.tone)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(machine.label)
                        if machine.key != machine.label { MachineChip(machine: machine.key) }
                    }
                    Text("ssh \(machine.target)" + (machine.session.isEmpty || machine.session == "default" ? "" : " · session \(machine.session)"))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(state.text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .animation(Motion.enter, value: machine)
    }
}

// MARK: - Phone

private struct PhonePane: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var tailnet = TailnetState.shared

    private var reach: String {
        guard s.remote else { return "Off: the phone link doesn't work; only this Mac can reach reflexd." }
        guard let t = tailnet.current else {
            return s.remoteLAN ? "reflexd listens on this Wi-Fi (unencrypted)." : "Needs Tailscale, or this Wi-Fi allowed below."
        }
        return t.userspace ? "Reachable from your tailnet only — Tailscale delivers it to this Mac's localhost."
                           : "reflexd listens on your network; your phone reaches it over Tailscale."
    }

    var body: some View {
        Form {
            Section { PaneHeader(pane: .phone) }
            Section {
                Toggle(isOn: Binding(get: { s.remote }, set: { s.remote = $0; Daemon.shared.restart() })) {
                    RowLabel("Allow the phone remote", reach)
                }
                LabeledContent {
                    if let t = tailnet.current {
                        Text(t.host ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text(tailnet.checked ? "Not found" : "Looking…").foregroundStyle(.secondary)
                    }
                } label: {
                    RowLabel("Tailscale", tailnet.current.map { $0.userspace ? "Running headless (userspace networking)." : "Running." }
                             ?? "Install Tailscale on this Mac and your phone for a private link that works anywhere.")
                }
                if tailnet.checked && tailnet.current == nil {
                    Toggle(isOn: Binding(get: { s.remoteLAN }, set: { s.remoteLAN = $0; if s.remote { Daemon.shared.restart() } })) {
                        RowLabel("Allow on this Wi-Fi", "Unencrypted: anyone on the network could read what passes — including the key that types into your agents. Only on networks you trust.")
                    }
                }
            }
            .onAppear { tailnet.refresh() }
            Section {
                LabeledContent {
                    Button("Pair a Phone…") { AppDelegate.current?.showPairing() }
                } label: {
                    RowLabel("Your phone", "Shows a code to scan. It works once and expires in 10 minutes — the same as ⋯ → Take Reflex with You on the rail.")
                }
                if s.remote {
                    LabeledContent {
                        Button("Sign Out Phones") { Settings.rotateToken(); Daemon.shared.restart() }
                    } label: {
                        RowLabel("Sign out", "Every phone that paired needs a new code.")
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
        let ok = [o.herdrInstalled, o.herdrRunning, o.integrations, o.jevInstalled && !o.jevTooOld, o.trusted]
        missing = ok.filter { !$0 }.count
    }
}

private struct SetupPane: View {
    @ObservedObject var o = Onboarding.shared
    @ObservedObject var s = Settings.shared
    @ObservedObject var store = Store.shared
    var openTour: () -> Void = { AppDelegate.current?.showOnboarding() }

    var body: some View {
        Form {
            Section { PaneHeader(pane: .setup) }
                .onAppear { o.refresh(); o.readHerdrServer(); o.askLatest() }
            Section("herdr-core") {
                CheckRow(ok: o.coreInstalled, title: "herdr-core installed", detail: o.coreInstalled ? o.coreDetail : o.installDetail(.core),
                         showAccessory: o.coreBehind) {
                    if !o.coreInstalled {
                        installButtons(.core)
                    } else {
                        Button(o.working == "herdr-core" ? "Updating…" : "Update") { o.updateCore() }
                            .disabled(o.working != nil)
                            .help("hc update: your agents keep running")
                    }
                }
                if s.usesCore {
                    CheckRow(ok: o.coreRunning, title: "herdr-core running",
                             detail: o.coreRunning ? (store.state.agents.count == 1 ? "1 agent" : "\(store.state.agents.count) agents") : "Run `hc server start` in a terminal.") {
                        Button("Start") { o.startCore() }.disabled(!o.coreInstalled)
                    }
                    CheckRow(ok: true, title: "Agent status", detail: o.statusDetail) {}
                }
            }
            Section(s.usesCore ? "herdr (agents still running there)" : "herdr") {
                CheckRow(ok: o.herdrInstalled, title: "herdr installed", detail: o.herdrInstalled ? o.herdrDetail : o.installDetail(.herdr),
                         showAccessory: o.herdrBehind || o.herdrRestartDue) {
                    if !o.herdrInstalled {
                        installButtons(.herdr)
                    } else if o.herdrBehind {
                        Button(o.working == "herdr" ? "Updating…" : "Update") { o.updateHerdr() }
                            .disabled(o.working != nil)
                            .help("herdr update")
                    } else {
                        Button(o.working == "herdr-restart" ? "Restarting…" : "Restart herdr…") { o.confirmHerdrRestart() }
                            .disabled(o.working != nil)
                    }
                }
                if !s.usesCore {
                    CheckRow(ok: o.herdrRunning, title: "herdr running",
                             detail: o.herdrRunning ? (store.state.agents.count == 1 ? "1 agent" : "\(store.state.agents.count) agents") : "Run `herdr` in a terminal.") {
                        Button("Copy Command") { o.copy("herdr") }
                    }
                }
                CheckRow(ok: o.integrations, title: "Agent integrations",
                         detail: o.integrations ? "Exact session ids, so side questions can fork the right session."
                             : "herdr can't see what \(o.unintegratedNames) is doing without it: no status, and its terminal window shows “no agent”.") {
                    Button(o.working == "integrations" ? "Installing…" : "Install") {
                        o.run("integrations", o.integrationCommand)
                    }
                    .disabled(o.working != nil)
                }
                if o.installed.contains("pi") {
                    CheckRow(ok: o.piShells, title: "pi background shells",
                             detail: "While pi-fabric shells still run after a turn, the session counts as working — no early “finished”, and the Mac stays awake. New pi sessions pick it up.") {
                        Button("Install") { o.installPiShells() }
                    }
                }
            }
            Section("Jev") {
                CheckRow(ok: o.jevInstalled && !o.jevTooOld, title: "jev-fabric installed", detail: o.jevInstalled ? o.jevDetail : o.installDetail(.jev), showAccessory: o.jevBehind) {
                    installButtons(.jev)
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

    /// Install, and once that has failed, the command to run by hand.
    @ViewBuilder private func installButtons(_ tool: Onboarding.Tool) -> some View {
        if o.failures[tool.rawValue] != nil { Button("Copy Command") { o.copy(tool.command) } }
        Button(o.installLabel(tool)) { o.install(tool) }
            .disabled(o.working != nil)
            .help(tool.command)
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
    @ObservedObject var updater = Updater.shared
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                    Text("Reflex").font(.system(size: 22, weight: .bold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–") · \(Bundle.main.object(forInfoDictionaryKey: "ReflexCommit") as? String ?? "dev"))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("One reflex to every coding agent in herdr. Routing by Jev, decisions in reflexd — written in Bend, with its laws proved.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            if Updater.available {
                Section {
                    LabeledContent {
                        Button(updater.pending == nil ? "Check for Updates…" : "Update…") { Updater.check() }
                    } label: {
                        RowLabel(updater.pending.map { "Reflex \($0) is available" } ?? "Updates",
                                 updater.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "Reflex checks once a day.")
                    }
                    Toggle(isOn: $updater.automaticallyInstalls) {
                        RowLabel("Install updates automatically", "Downloaded in the background and installed when Reflex next quits.")
                    }
                }
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
