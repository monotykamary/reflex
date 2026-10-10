import AppKit
import SwiftUI

// First run: six short steps, each one checking itself live — herdr running,
// Jev answering (with its real latency), your projects indexed, ⌥⌥ and the
// edge gesture actually tried. Seen once, so it may move a little more than
// the everyday UI; it still never makes you wait for an animation.

@MainActor
final class Onboarding: ObservableObject {
    static let shared = Onboarding()

    enum Step: Int, CaseIterable { case welcome, herdr, jev, projects, keys, done }
    enum Ping: Equatable {
        case idle, testing, ok(Int), failed(String)
        var isOK: Bool { if case .ok = self { return true } else { return false } }
    }

    @Published var step: Step = .welcome
    @Published var forward = true
    @Published var herdrInstalled = false
    @Published var integrations = false
    @Published var jevInstalled = false
    @Published var ping: Ping = .idle
    @Published var installed: Set<String> = []
    @Published var folders: [FolderInfo] = []
    @Published var trusted = false
    @Published var triedHotkey = false
    @Published var triedEdge = false
    @Published var working: String?
    /// "Try a reflex": a real request, routed dry — nothing is sent.
    enum Trial: Equatable { case idle, routing, routed(label: String, why: String, ms: Int), failed(String) }
    @Published var trial: Trial = .idle
    @Published var trialText = ""
    var close: () -> Void = {}
    private(set) var isOpen = false
    private var poll: Timer?

    static let harnesses = ["claude", "codex", "pi", "grok", "opencode", "amp", "gemini"]

    func begin(at step: Step = .welcome) {
        self.step = step
        isOpen = true
        refresh()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if step == .jev { test() }
        if step == .projects || step == .jev { Task { await loadFolders() } }
    }

    func end() {
        Settings.shared.onboarded = true
        closed()
        close()
    }

    /// The window went away (finished or closed).
    func closed() {
        isOpen = false
        poll?.invalidate()
    }

    func go(_ s: Step) {
        forward = s.rawValue >= step.rawValue
        withAnimation(Motion.enter) { step = s }
        if s == .jev, ping == .idle { test() }
        if s == .projects || s == .jev { Task { await loadFolders() } }
        if s == .done, !(ping.isOK) { test() }
    }

    func next() { if let n = Step(rawValue: step.rawValue + 1) { go(n) } else { end() } }
    func back() { if let p = Step(rawValue: step.rawValue - 1) { go(p) } }

    // MARK: Checks

    private static func which(_ name: String) -> Bool {
        let path = Daemon.shared.childEnvironment()["PATH"] ?? ""
        return path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    func refresh() {
        herdrInstalled = Onboarding.which("herdr")
        jevInstalled = Onboarding.which("jev-fabric")
        installed = Set(Onboarding.harnesses.filter { Onboarding.which($0) })
        let home = NSHomeDirectory()
        integrations = FileManager.default.fileExists(atPath: home + "/.claude/hooks/herdr-agent-state.sh")
            || FileManager.default.fileExists(atPath: home + "/.pi/agent/extensions/herdr-agent-state.ts")
        trusted = DoubleOption.trusted
        if folders.isEmpty && Store.shared.state.folders > 0 { Task { await loadFolders() } }
    }

    var herdrRunning: Bool { Store.shared.connected && Store.shared.state.herdr }

    func loadFolders() async {
        folders = Array(await Client.local.folders("").prefix(8))
    }

    // MARK: Actions

    /// A request worth trying, about a folder you actually have.
    var trialSuggestion: String {
        if let f = folders.first(where: { !$0.name.isEmpty }) { return "fix the flaky test in \(f.name)" }
        return "add a dark mode toggle to the settings page"
    }

    func tryRoute(attempt: Int = 0) {
        let text = (trialText.isEmpty ? trialSuggestion : trialText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, attempt > 0 || trial != .routing else { return }
        if trialText.isEmpty { trialText = text }
        withAnimation(Motion.enter) { trial = .routing }
        let start = Date()
        Task {
            let ms = { Int(Date().timeIntervalSince(start) * 1000) }
            do {
                let r = try await Client.local.route(text, dry: true)
                let error = r.route?.error ?? r.error
                // Right after launch reflexd is still indexing: wait for it.
                if let e = error, e.contains("nothing to route to"), attempt < 8 {
                    trial = .routing
                    try? await Task.sleep(for: .seconds(2))
                    guard trialText == text || trialText.isEmpty else { return }
                    tryRoute(attempt: attempt + 1)
                    return
                }
                let next: Trial
                if let route = r.route, error == nil {
                    let label = route.label ?? route.title ?? (route.decision == "choose" ? "you pick: 1, 2 or 3" : route.decision)
                    next = .routed(label: label.bare, why: route.why ?? (route.decision == "choose" ? "not sure enough — it would ask you" : ""), ms: ms())
                } else {
                    next = .failed(error ?? "no answer")
                }
                withAnimation(Motion.arrive) { trial = next }
            } catch {
                withAnimation(Motion.enter) { trial = .failed("reflexd is not answering yet") }
            }
        }
    }

    func run(_ label: String, _ command: String) {
        working = label
        let env = Daemon.shared.childEnvironment()
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            await MainActor.run {
                self.working = nil
                self.refresh()
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func usePiKey() {
        guard let cmd = Settings.piCredentialCommand else { return }
        Settings.shared.jevProvider = "typesafe"
        Settings.shared.jevCredentialCommand = cmd
        restartAndTest()
    }

    func saveKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        Settings.jevKey = k
        Settings.shared.jevCredentialCommand = ""
        restartAndTest()
    }

    private func restartAndTest() {
        Daemon.shared.restart()
        ping = .testing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.test() }
    }

    func test() {
        ping = .testing
        Task {
            struct R: Decodable { var ok: Bool; var ms: Int?; var error: String? }
            do {
                let r = try await Client.local.post("/api/jev/ping", [:], as: R.self)
                withAnimation(Motion.enter) { ping = r.ok ? .ok(r.ms ?? 0) : .failed(r.error ?? "no answer") }
            } catch {
                withAnimation(Motion.enter) { ping = .failed("reflexd is not answering yet") }
            }
        }
    }

    func setRoots(_ roots: [String]) {
        Settings.shared.roots = roots.joined(separator: ":")
        Daemon.shared.restart()
        Task {
            try? await Task.sleep(for: .seconds(9))
            await loadFolders()
        }
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        var roots = Settings.shared.roots.split(separator: ":").map(String.init)
        for u in panel.urls where !roots.contains(u.path) { roots.append(u.path) }
        setRoots(roots)
    }

    func pick(_ harness: String) {
        Settings.shared.harness = harness
        Daemon.shared.restart()
    }

    /// While the keyboard step is open, ⌥⌥ is practice: it checks the box
    /// instead of opening the bar.
    func consumeHotkey() -> Bool {
        guard isOpen, step == .keys else { return false }
        withAnimation(Motion.arrive) { triedHotkey = true }
        return true
    }

    func noteEdgeReveal() {
        guard isOpen, step == .keys else { return }
        withAnimation(Motion.arrive) { triedEdge = true }
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var model = Onboarding.shared
    @ObservedObject var store = Store.shared
    @ObservedObject var settings = Settings.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var key = ""

    var body: some View {
        ZStack {
            Backdrop()
            HStack(spacing: 0) {
                copy
                    .frame(width: 400, alignment: .leading)
                    .padding(.leading, 48)
                    .padding(.trailing, 28)
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, 36)
            }
            .padding(.top, 52)
            .padding(.bottom, 92)
            VStack { Spacer(); footer }
        }
        .frame(width: 920, height: 600)
        .environment(\.colorScheme, .dark)
        .onKeyPress(.return) {
            // On the Jev step, Return routes the trial request instead.
            guard model.step != .jev else { return .ignored }
            model.next()
            return .handled
        }
    }

    // MARK: Copy column

    private var copy: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(eyebrow)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))
            Text(title)
                .font(OnboardType.display)
                .tracking(-1.3)
                .lineSpacing(-4)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(lede)
                .font(.system(size: 15, weight: .regular))
                .tracking(-0.1)
                .foregroundStyle(.white.opacity(0.72))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            checks.padding(.top, 8)
            Spacer(minLength: 0)
        }
        .id(model.step)
        .transition(.asymmetric(
            insertion: .modifier(active: SurfaceFX(opacity: 0, scale: 1, y: 10, blur: 6), identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0)),
            removal: .modifier(active: SurfaceFX(opacity: 0, scale: 1, y: -6, blur: 4), identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0))))
    }

    private var eyebrow: String {
        switch model.step {
        case .welcome: return "Reflex"
        case .herdr: return "1 of 4 · Your agents"
        case .jev: return "2 of 4 · The reflex"
        case .projects: return "3 of 4 · Your work"
        case .keys: return "4 of 4 · Your hands"
        case .done: return "Ready"
        }
    }

    private var title: String {
        switch model.step {
        case .welcome: return "Every agent,\none reflex away."
        case .herdr: return "Agents live\nin herdr."
        case .jev: return "A reflex,\nnot a conversation."
        case .projects: return "Where do\nyou work?"
        case .keys: return "Two taps,\none edge."
        case .done: return "Welcome to\nReflex."
        }
    }

    private var lede: String {
        switch model.step {
        case .welcome:
            return "Reflex sends what you say to the right coding agent — or starts one in the right folder — and brings back everything that needs you. Your agents keep running in their own terminals, on the plans you already have."
        case .herdr:
            return "Reflex sees and talks to agents through herdr, a terminal built for them. Run your agents in it; Reflex reads their state, answers their questions and opens their terminals."
        case .jev:
            return "No chat model rewrites your words. Jev, a System 1 model, answers typed questions — which session, which folder, is it a side question — in about a second. Unsure, it asks you instead. Try one: nothing is sent."
        case .projects:
            return "Reflex indexes the repositories under these folders — names, descriptions, recent commits — so a request like “fix the flaky test in jev fabric” starts in the right place."
        case .keys:
            return "Double-tap ⌥ anywhere to ask. Rest your pointer on the right edge for half a second to see your agents. Try both now."
        case .done:
            return "Your card, and everything in one breath. All of this lives in Settings too."
        }
    }

    // MARK: Checklists

    @ViewBuilder private var checks: some View {
        switch model.step {
        case .welcome:
            EmptyView()
        case .herdr:
            VStack(alignment: .leading, spacing: 10) {
                Check(ok: model.herdrInstalled, title: "herdr installed", detail: model.herdrInstalled ? nil : "brew install herdr") {
                    if !model.herdrInstalled { GlassAction("Copy") { model.copy("brew install herdr") } }
                }
                Check(ok: model.herdrRunning, title: "herdr running", detail: model.herdrRunning ? (store.state.agents.count == 1 ? "1 agent" : "\(store.state.agents.count) agents") : "run `herdr` in your terminal") {
                    if !model.herdrRunning { GlassAction("Copy") { model.copy("herdr") } }
                }
                Check(ok: model.integrations, title: "Agent integrations", detail: model.integrations ? "exact sessions for side questions" : "lets side questions fork the exact session") {
                    if !model.integrations {
                        GlassAction(model.working == "integrations" ? "Installing…" : "Install") {
                            model.run("integrations", "herdr integration install claude; herdr integration install pi")
                        }
                    }
                }
            }
        case .jev:
            VStack(alignment: .leading, spacing: 10) {
                Check(ok: model.jevInstalled, title: "jev-fabric installed",
                      detail: model.jevInstalled ? nil : "curl -fsSL https://raw.githubusercontent.com/fabric-runtime/jev-fabric/main/install.sh | sh") {
                    if !model.jevInstalled {
                        GlassAction("Copy") { model.copy("curl -fsSL https://raw.githubusercontent.com/fabric-runtime/jev-fabric/main/install.sh | sh") }
                    }
                }
                Check(ok: pingOK, title: "Jev answering", detail: pingDetail) {
                    GlassAction(model.ping == .testing ? "Testing…" : "Test") { model.test() }
                }
                if !pingOK {
                    if Settings.piCredentialCommand != nil {
                        Button { model.usePiKey() } label: {
                            Label("Use the TypeSafe key pi already has", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Tone.working)
                        .controlSize(.large)
                    }
                    HStack {
                        SecureField("…or paste a TypeSafe API key", text: $key)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .glassEffect(.regular, in: Capsule())
                            .onSubmit { model.saveKey(key); key = "" }
                        GlassAction("Save") { model.saveKey(key); key = "" }
                    }
                }
            }
        case .projects:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(settings.roots.split(separator: ":").map(String.init), id: \.self) { root in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Tone.working)
                        Text(root.abbreviatingHome).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button {
                            model.setRoots(settings.roots.split(separator: ":").map(String.init).filter { $0 != root })
                        } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .pane(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                HStack {
                    GlassAction("Add folder…") { model.addRoot() }
                    Spacer()
                    Text(store.state.folders == 0 ? "indexing…" : "\(store.state.folders) repositories")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.numericText(value: Double(store.state.folders)))
                }
                Text("New sessions start with").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).padding(.top, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                    ForEach(Onboarding.harnesses, id: \.self) { h in
                        let on = settings.harness == h
                        let have = model.installed.contains(h)
                        Button { model.pick(h) } label: {
                            Text(h).font(.system(size: 12, weight: on ? .semibold : .regular))
                                .lineLimit(1).fixedSize()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .opacity(have ? 1 : 0.4)
                        }
                        .buttonStyle(Pressable())
                        .glassEffect(on ? .regular.tint(Tone.working.opacity(0.45)) : .regular, in: Capsule())
                        .disabled(!have)
                        .help(have ? h : "\(h) is not installed")
                    }
                }
            }
        case .keys:
            VStack(alignment: .leading, spacing: 10) {
                Check(ok: model.trusted, title: "Accessibility", detail: model.trusted ? "⌥⌥ works everywhere" : "needed to hear ⌥⌥ in other apps") {
                    if !model.trusted { GlassAction("Allow…") { AccessGuide.shared.start() } }
                }
                Check(ok: model.triedHotkey, title: "Double-tap ⌥", detail: model.triedHotkey ? "that's the one" : "try it now") { EmptyView() }
                Check(ok: model.triedEdge, title: "Rest on the right edge", detail: model.triedEdge ? "there they are" : "move to the edge and hold still for half a second") { EmptyView() }
            }
        case .done:
            VStack(alignment: .leading, spacing: 9) {
                Cheat(keys: "⌥⌥", what: "Ask — Jev routes it")
                Cheat(keys: "⇥", what: "Pin an agent instead of routing")
                Cheat(keys: "btw", what: "Ask on the side, without interrupting")
                Cheat(keys: "esc", what: "Undo during the 2-second window")
                Cheat(keys: "edge", what: "Rest on the right edge to see agents")
                Cheat(keys: "J K 1–9", what: "Move and answer in the inbox")
            }
        }
    }

    private var pingOK: Bool { if case .ok = model.ping { return true } else { return false } }

    private var pingDetail: String {
        switch model.ping {
        case .idle: return "not tested yet"
        case .testing: return "asking Jev…"
        case .ok(let ms): return "answered in \(ms) ms"
        case .failed(let e): return e
        }
    }

    // MARK: Stage (illustrations)

    private var stage: some View {
        ZStack {
            switch model.step {
            case .welcome: EdgeStory()
            case .herdr: PanesIllustration(agents: store.state.agents)
            case .jev: TryReflex(model: model)
            case .projects: FoldersIllustration(folders: model.folders)
            case .keys: KeysIllustration(hotkey: model.triedHotkey, edge: model.triedEdge)
            case .done: MemberCard(repos: store.state.folders, agents: store.state.agents.count,
                                   harness: settings.harness, ping: model.ping)
            }
        }
        .id(model.step)
        .transition(.asymmetric(
            insertion: .modifier(active: SurfaceFX(opacity: 0, scale: 0.96, y: 0, blur: 8), identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0)),
            removal: .modifier(active: SurfaceFX(opacity: 0, scale: 1.02, y: 0, blur: 6), identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0))))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Onboarding.Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(.white.opacity(s == model.step ? 0.9 : (s.rawValue < model.step.rawValue ? 0.45 : 0.18)))
                        .frame(width: s == model.step ? 22 : 7, height: 7)
                        .onTapGesture { model.go(s) }
                }
            }
            .animation(Motion.spring, value: model.step)
            Spacer()
            if model.step != .welcome && model.step != .done {
                Button("Back") { model.back() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            Button {
                model.next()
            } label: {
                Text(primaryLabel).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent)
            .tint(Tone.working)
            .controlSize(.large)
            .keyboardShortcut(model.step == .jev ? nil : .defaultAction)
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 32)
    }

    private var primaryLabel: String {
        switch model.step {
        case .welcome: return "Get started"
        case .done: return "Start using Reflex"
        case .herdr: return model.herdrRunning ? "Continue" : "Skip for now"
        case .jev: return pingOK ? "Continue" : "Skip for now"
        case .keys: return model.triedHotkey || model.triedEdge ? "Continue" : "Skip for now"
        default: return "Continue"
        }
    }
}

// MARK: - Pieces

private struct Check<Accessory: View>: View {
    var ok: Bool
    var title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().strokeBorder(.white.opacity(ok ? 0 : 0.25), lineWidth: 1.5)
                if ok {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Tone.done)
                        .transition(.symbolEffect(.drawOn))
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2).textSelection(.enabled)
                        .contentTransition(.interpolate)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .pane(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: ok ? Tone.done : nil)
        .animation(Motion.enter, value: ok)
    }
}

private struct GlassAction: View {
    var title: String
    var action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    var body: some View {
        Button(title, action: action).buttonStyle(.glass).controlSize(.small)
    }
}

private struct Cheat: View {
    var keys: String
    var what: String
    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .pane(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .frame(minWidth: 70, alignment: .leading)
            Text(what).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// Liquid Glass, untinted: the desktop frosted behind the whole window, the
/// same glass as the rail.
private struct Backdrop: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .glassTone(Rectangle())
            .glassEffect(.regular, in: .rect)
            .ignoresSafeArea()
    }
}

// MARK: - Illustrations

private struct PanesIllustration: View {
    var agents: [AgentInfo]
    private var rows: [(String, String)] {
        let live = agents.prefix(4).map { ("\($0.kind) · \($0.folder)", $0.status) }
        return live.isEmpty ? [("claude · api", "working"), ("pi · web", "blocked"), ("codex · infra", "done")] : Array(live)
    }
    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                HStack(spacing: 10) {
                    Bead(status: r.1, size: 8)
                    Text(r.0).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text(r.1).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color(hex: "#1a1b26").opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .transition(.surface().animation(Motion.enter.delay(Double(i) * 0.06)))
            }
        }
        .frame(width: 330)
        .padding(18)
        .pane(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct FoldersIllustration: View {
    var folders: [FolderInfo]
    private var names: [(String, String)] {
        folders.isEmpty ? [("api", "Payments API"), ("web", "Marketing site"), ("infra", "Terraform"), ("jev-fabric", "Native process orchestration")]
            : folders.prefix(6).map { ($0.name, $0.desc) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, f in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Tone.working.opacity(0.9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.0).font(.system(size: 13, weight: .semibold))
                        if !f.1.isEmpty { Text(f.1).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .pane(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.surface().animation(Motion.enter.delay(Double(i) * 0.05)))
            }
        }
        .frame(width: 320)
    }
}

private struct KeysIllustration: View {
    var hotkey: Bool
    var edge: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 12) {
                cap(delay: 0)
                cap(delay: 0.22)
                if hotkey {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Tone.done)
                        .transition(.symbolEffect(.drawOn))
                }
            }
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
                    .frame(width: 300, height: 170)
                EdgeDemo(done: edge)
            }
            .frame(width: 300, height: 170)
        }
    }

    private func cap(delay: Double) -> some View {
        PhaseAnimator([false, true, false], trigger: reduce) { down in
            Text("⌥")
                .font(.system(size: 28, weight: .medium))
                .frame(width: 64, height: 58)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(down && !reduce ? 0.93 : 1)
                .offset(y: down && !reduce ? 2 : 0)
        } animation: { down in
            down ? .timingCurve(0.23, 1, 0.32, 1, duration: 0.12).delay(delay) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.5).delay(0.9)
        }
    }
}

/// The edge gesture, demonstrated: a sliver grows, then the rail appears.
private struct EdgeDemo: View {
    var done: Bool
    @State private var grow = false
    var body: some View {
        HStack(spacing: 8) {
            if done {
                VStack(spacing: 10) {
                    Bead(status: "working", size: 8)
                    Bead(status: "blocked", size: 8)
                    Bead(status: "done", size: 8)
                }
                .padding(.vertical, 12).padding(.horizontal, 8)
                .glassEffect(.regular, in: Capsule())
                .transition(.surface())
            } else {
                Capsule()
                    .fill(Color.accentColor.opacity(grow ? 0.85 : 0.25))
                    .frame(width: 4, height: grow ? 80 : 18)
                    .shadow(color: Color.accentColor.opacity(grow ? 0.6 : 0), radius: 6)
            }
        }
        .padding(.trailing, 4)
        .animation(Motion.spring, value: done)
        .task(id: done) {
            while !done && !Task.isCancelled {
                withAnimation(.linear(duration: 1.0)) { grow = true }
                try? await Task.sleep(for: .milliseconds(1400))
                withAnimation(Motion.exit) { grow = false }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }
}

// MARK: - Welcome: the edge, told in five seconds

/// A tiny screen: a tab grows out of its right edge, agents light up one by
/// one, a question buds out, gets answered with "1", and drains away.
private struct EdgeStory: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var beat = 0

    private var glyphs: [String] {
        switch beat {
        case 0: return []
        case 1: return ["working"]
        case 2: return ["working", "blocked"]
        case 3, 4: return ["working", "blocked", "done"]
        default: return ["working", "working", "done"]
        }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // The "screen": a few quiet windows.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.09)))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    Capsule().fill(.white.opacity(0.06)).frame(width: [180, 230, 140, 210, 120, 190][i], height: 7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(26)

            HStack(spacing: 10) {
                if beat == 4 { question.transition(.surface(reduce: reduce)) }
                if beat >= 1 {
                    VStack(spacing: 10) {
                        ForEach(Array(glyphs.enumerated()), id: \.offset) { _, g in
                            AgentGlyph(status: g, size: 11)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 9 + 12).padding(.leading, 8).padding(.trailing, 7)
                    .glassEffect(.rail, in: EdgeTabShape())
                    .transition(.opacity.combined(with: .offset(x: reduce ? 0 : 14)))
                }
            }
        }
        .frame(width: 380, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(Motion.spring, value: beat)
        .task {
            if reduce { beat = 4; return }
            while !Task.isCancelled {
                for (b, wait) in [(0, 500), (1, 600), (2, 600), (3, 700), (4, 1900), (5, 1800)] {
                    beat = b
                    try? await Task.sleep(for: .milliseconds(wait))
                }
            }
        }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentGlyph(status: "blocked", size: 9)
                Text("claude · api").font(.system(size: 12, weight: .semibold))
            }
            Text("Run the migration now?").font(.system(size: 12.5))
            HStack(spacing: 6) {
                KeyCap(key: "1", tint: Tone.blocked); Text("Yes").font(.system(size: 11.5))
                KeyCap(key: "2", tint: Tone.blocked); Text("Not yet").font(.system(size: 11.5))
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .glassEffect(.regular.tint(Color.black.opacity(0.6)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Jev: try a reflex

/// A real request, routed for real but dry: you see where it would go and
/// how long Jev took. Nothing is sent.
private struct TryReflex: View {
    @ObservedObject var model: Onboarding
    @FocusState private var focused: Bool

    private var examples: [String] {
        var out = [model.trialSuggestion]
        if let f = model.folders.dropFirst().first { out.append("what changed in \(f.name) this week?") }
        out.append("btw why is the build slow?")
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try a reflex").font(.system(size: 11, weight: .semibold)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(Tone.route)
                TextField("", text: $model.trialText, prompt: Text(model.trialSuggestion).foregroundStyle(.white.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { model.tryRoute() }
                    .onChange(of: model.trialText) { _, _ in if model.trial != .routing { model.trial = .idle } }
                KeyCap(key: "⏎", tint: .white)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .glassEffect(.regular.tint(Color.black.opacity(0.4)).interactive(), in: Capsule())
            .overlay(alignment: .bottom) {
                if model.trial == .routing { ThinkingLine().frame(height: 2).padding(.horizontal, 24).clipShape(Capsule()) }
            }

            result.frame(minHeight: 96, alignment: .top)

            HStack(spacing: 6) {
                ForEach(examples, id: \.self) { e in
                    Button { model.trialText = e; model.tryRoute() } label: {
                        Text(e).font(.system(size: 11.5)).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .buttonStyle(Pressable())
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 400)
        .onAppear { focused = true }
    }

    @ViewBuilder private var result: some View {
        switch model.trial {
        case .idle:
            Text("Press Return. Jev decides where it would go — a session, a new one in a folder, or a side question. Nothing is sent.")
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        case .routing:
            Text(Store.shared.state.folders == 0 ? "Reading your projects, then asking Jev…" : "Asking Jev…")
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
        case .routed(let label, let why, let ms):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tone.done)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.tint(Tone.done.opacity(0.25)), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    if !why.isEmpty { Text(why).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)) }
                    Text(verbatim: "jev · \(ms) ms · dry run, nothing sent").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pane(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: Tone.done)
            .transition(.surface())
        case .failed(let e):
            Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Tone.blocked)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Done: your Reflex card

/// Arc gave you a membership card; Reflex gives you one too, made from your
/// setup. It leans toward the pointer.
private struct MemberCard: View {
    var repos: Int
    var agents: Int
    var harness: String
    var ping: Onboarding.Ping
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var tilt = CGSize.zero
    @State private var shown = false

    private var name: String {
        let n = NSFullUserName()
        return n.isEmpty ? NSUserName() : n
    }

    private var since: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: Date())
    }

    private var jev: String {
        if case .ok(let ms) = ping { return "\(ms) ms" }
        return "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("REFLEX").font(.system(size: 13, weight: .bold)).tracking(4)
                Spacer()
                HStack(spacing: 6) {
                    AgentGlyph(status: "working", size: 10)
                    AgentGlyph(status: "blocked", size: 10)
                    AgentGlyph(status: "done", size: 10)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .glassEffect(.regular.tint(Color.black.opacity(0.6)), in: Capsule())
            }
            Spacer()
            Text(name).font(.system(size: 26, weight: .semibold)).tracking(-0.7).lineLimit(1).minimumScaleFactor(0.6)
            Text("Member since \(since)").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).padding(.top, 2)
            Spacer().frame(height: 18)
            HStack(spacing: 0) {
                stat("\(repos)", "repos")
                stat("\(agents)", agents == 1 ? "agent" : "agents")
                stat(harness, "starts new")
                stat(jev, "jev")
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(width: 380, height: 240)
        .glassEffect(.regular.tint(Color.black.opacity(0.45)).interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .rotation3DEffect(.degrees(Double(tilt.height) * 9), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(Double(-tilt.width) * 11), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .scaleEffect(shown || reduce ? 1 : 0.92)
        .opacity(shown || reduce ? 1 : 0)
        .rotation3DEffect(.degrees(shown || reduce ? 0 : 14), axis: (x: 1, y: 0, z: 0))
        .onContinuousHover { phase in
            guard !reduce else { return }
            switch phase {
            case .active(let p):
                withAnimation(.spring(duration: 0.4, bounce: 0)) {
                    tilt = CGSize(width: (p.x - 190) / 190, height: (p.y - 120) / 120)
                }
            case .ended:
                withAnimation(.spring(duration: 0.6, bounce: 0.2)) { tilt = .zero }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(Motion.arrive) { shown = true }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Styling

enum OnboardType {
    /// Headlines: SF Pro Display, heavy and tightly tracked.
    static let display = Font.system(size: 42, weight: .bold)
}

private extension View {
    /// A content surface on the glass window: a faint fill and a hairline,
    /// so cards read as layers of the glass rather than glass on glass.
    func pane<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        background((tint ?? .white).opacity(tint == nil ? 0.07 : 0.12), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}
