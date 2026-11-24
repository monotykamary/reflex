import SwiftUI

// Settings › Profiles: the harnesses' other accounts (`reflex profile`), how
// each login is kept signed in everywhere (`reflex-keys`: one Mac refreshes
// it and pushes it to the rest), and which one each machine starts a bare
// agent in (`reflex profile default`).

/// One profile's login, as `reflex-keys status --json` reports it.
struct ProfileLogin: Decodable, Identifiable, Hashable {
    let profile: String
    let holder: String
    let here: String
    let login: String
    let expires: Double?
    let loginEnds: Double?
    let current: [String]
    let behind: [String]
    let error: String?
    let warnings: [String]?
    var id: String { profile }
    var harness: String { Profiles.split(profile).kind }
    var name: String { Profiles.split(profile).profile }
}

@MainActor
final class ProfilesModel: ObservableObject {
    static let shared = ProfilesModel()

    /// A machine and the profiles on it: which harnesses have one, and its defaults.
    struct Place: Identifiable, Hashable {
        /// herdr-core's name, "" for this Mac.
        let name: String
        let title: String
        var connected: Bool
        /// Its profiles, as specs ("claude[tom]").
        var profiles: [String] = []
        /// harness → the profile a bare one starts in there.
        var defaults: [String: String] = [:]
        var read = false
        var id: String { name.isEmpty ? "." : name }
    }

    @Published private(set) var logins: [ProfileLogin] = []
    @Published private(set) var places: [Place] = []
    @Published private(set) var busy: Set<String> = []
    @Published var failure: String?
    @Published private(set) var loaded = false

    /// The harnesses in the order Reflex shows them (most used first).
    nonisolated static let harnesses = ["claude", "codex", "agy", "pi", "opencode", "amp", "grok"]

    func load() async {
        let logins = await Blocking.run { Self.keysStatus() }
        let script = Boat.script
        let here = await Blocking.run { Self.run(script, ["profile", "ls"]) }
        var next = [Self.place("", Host.current().localizedName ?? "This Mac", connected: true, ls: here)]
        for m in await CoreMachines.list(fresh: 5) {
            let up = m.state == "connected"
            let prior = places.first { $0.name == m.name }
            guard up else {
                var p = prior ?? Place(name: m.name, title: m.name, connected: false)
                p.connected = false
                next.append(p)
                continue
            }
            let out = await Blocking.run {
                CoreMachines.exec(m.name, #"PATH="$HOME/.local/bin:$PATH"; reflex profile ls"#, input: "", timeout: 20)
            }
            if let out { next.append(Self.place(m.name, m.name, connected: true, ls: out)) }
            else { next.append(prior ?? Place(name: m.name, title: m.name, connected: true)) }
        }
        self.logins = logins
        self.places = next
        loaded = true
    }

    /// `reflex profile ls`: "claude[tom]" a line, "\tdefault here" after a machine's default.
    nonisolated static func place(_ name: String, _ title: String, connected: Bool, ls: String?) -> Place {
        var p = Place(name: name, title: title, connected: connected)
        guard let ls else { return p }
        p.read = true
        for line in ls.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard let spec = f.first, spec.hasSuffix("]") else { continue }
            p.profiles.append(spec)
            if f.count > 1, f[1].contains("default") {
                let (k, n) = Profiles.split(spec)
                p.defaults[k] = n
            }
        }
        return p
    }

    /// The profiles a harness has on that machine (their names).
    func names(_ harness: String, on p: Place) -> [String] {
        p.profiles.map(Profiles.split).filter { $0.kind == harness }.map(\.profile).sorted()
    }

    func key(_ p: Place, _ harness: String) -> String { "\(p.id)|\(harness)" }

    /// Make `name` (or "" for your own) what a bare `harness` starts as on that machine.
    func setDefault(_ p: Place, harness: String, to name: String) {
        let k = key(p, harness)
        guard !busy.contains(k) else { return }
        busy.insert(k)
        let spec = "\(harness)[\(name)]"
        Task {
            let ok: Bool
            let script = Boat.script
            if p.name.isEmpty {
                ok = await Blocking.run { Self.run(script, ["profile", "default", spec]) != nil }
            } else {
                ok = await Blocking.run {
                    // (A spec is letters, digits and . _ - : safe in single quotes.)
                    CoreMachines.exec(p.name, #"PATH="$HOME/.local/bin:$PATH"; reflex profile default '"# + spec + "'",
                                      input: "", timeout: 20) != nil
                }
            }
            if ok, let i = places.firstIndex(where: { $0.id == p.id }) {
                places[i].defaults[harness] = name.isEmpty ? nil : name
            } else if !ok {
                failure = "Couldn't set \(spec) as \(p.name.isEmpty ? "this Mac" : p.name)'s default."
            }
            busy.remove(k)
        }
    }

    nonisolated static func keysStatus() -> [ProfileLogin] {
        let bin = NSHomeDirectory() + "/.local/bin/reflex-keys"
        guard let out = run(bin, ["status", "--json"]),
              let xs = try? JSONDecoder().decode([ProfileLogin].self, from: Data(out.utf8)) else { return [] }
        return xs.sorted { (harnessOrder($0.harness), $0.name) < (harnessOrder($1.harness), $1.name) }
    }

    nonisolated static func harnessOrder(_ h: String) -> Int { harnesses.firstIndex(of: h) ?? harnesses.count }

    /// A program's output when it exits 0 (a shell script through /bin/sh).
    nonisolated static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        if path.hasSuffix(".sh") {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [path] + args
        } else {
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
        }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
    }
}

/// How each harness looks in Reflex.
enum HarnessLook {
    static func symbol(_ h: String) -> String {
        switch h {
        case "claude": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "agy": return "atom"
        case "pi": return "p.circle.fill"
        case "opencode": return "curlybraces"
        case "amp": return "bolt.fill"
        case "grok": return "xmark"
        default: return "terminal.fill"
        }
    }
    static func tint(_ h: String) -> Color {
        switch h {
        case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": return Color(red: 0.42, green: 0.45, blue: 0.98)
        case "agy": return Color(red: 0.26, green: 0.52, blue: 0.96)
        case "pi": return Color(red: 0.55, green: 0.36, blue: 0.96)
        case "opencode": return Color(red: 0.93, green: 0.62, blue: 0.16)
        case "amp": return Color(red: 0.95, green: 0.33, blue: 0.24)
        case "grok": return Color(white: 0.55)
        default: return Color(white: 0.45)
        }
    }
}

/// A harness's own mark (app/Resources/logos, see PROVENANCE.md), on a tile
/// the same size for every harness. One-colour marks are drawn in the text
/// colour; a harness with no mark gets its symbol.
struct HarnessLogo: View {
    let harness: String
    var size: CGFloat = 30
    var tile = true

    nonisolated static let images: [String: NSImage] = {
        var out: [String: NSImage] = [:]
        // (The app's Resources/logos, or the checkout's app/Resources/logos under REFLEX_DEV_ROOT.)
        let root = ProcessInfo.processInfo.environment["REFLEX_DEV_ROOT"].map { $0 + "/app/Resources" } ?? (Bundle.main.resourcePath ?? ".")
        let dir = root + "/logos"
        for h in ["claude", "codex", "agy", "amp", "grok", "opencode"] {
            guard let im = NSImage(contentsOfFile: "\(dir)/\(h).png") else { continue }
            im.isTemplate = ["grok", "opencode"].contains(h)
            out[h] = im
        }
        return out
    }()

    var body: some View {
        let mark = Group {
            if let im = Self.images[harness] {
                Image(nsImage: im).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: HarnessLook.symbol(harness)).resizable().aspectRatio(contentMode: .fit)
                    .fontWeight(.semibold).foregroundStyle(HarnessLook.tint(harness))
            }
        }
        if tile {
            mark.padding(size * 0.17)
                .frame(width: size, height: size)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        } else {
            mark.frame(width: size, height: size)
        }
    }
}

struct ProfilesPane: View {
    @ObservedObject private var model = ProfilesModel.shared
    @ObservedObject private var kinds = MachineKinds.shared
    @State private var copied = false

    var body: some View {
        Form {
            Section { PaneHeader(pane: .profiles) }
            accounts
            defaults
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add a profile").font(Type.title)
                        Text("In a terminal: sign it in, then hand it to this Mac to keep fresh and share.")
                            .font(Type.meta).foregroundStyle(.secondary)
                        Text("reflex profile login 'claude[work]'\nreflex keys seed 'claude[work]'")
                            .font(Type.mono).textSelection(.enabled).padding(.top, 2)
                    }
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("reflex profile login 'claude[work]' && reflex keys seed 'claude[work]'", forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
            }
        }
        .alert("Couldn't change it", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) { model.failure = nil }
        } message: { Text(model.failure ?? "") }
        .task {
            while !Task.isCancelled {
                await model.load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    // MARK: Accounts

    private var accounts: some View {
        Section {
            if model.logins.isEmpty {
                Text(model.loaded ? "No profile is kept here yet. Sign one in and hand it over (below)." : "Reading…")
                    .font(Type.meta).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)],
                          alignment: .leading, spacing: 10) {
                    ForEach(model.logins) { LoginCard(login: $0) }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("A login's refresh token works once, so one Mac (its keeper) refreshes it early and pushes it to every other machine, which never holds a usable one. Claude's own daemon refreshes Claude's.")
                .font(Type.meta).foregroundStyle(.secondary)
        }
    }

    // MARK: Defaults

    private var defaults: some View {
        Section {
            ForEach(model.places) { p in
                PlaceRow(place: p, symbol: kinds.symbol(p.name.isEmpty ? Boat.here : p.name))
            }
        } header: {
            Text("Default on each machine")
        } footer: {
            Text("A bare agent on that machine (claude, codex, agy…) starts in its default. /claude[tom] in the ⌥⌥ bar picks one for a single session; \"Your own\" is the login in your home folder. A session stays in the profile it started in.")
                .font(Type.meta).foregroundStyle(.secondary)
        }
    }
}

/// One profile's login: who keeps it, how long it lasts, where it is current.
private struct LoginCard: View {
    let login: ProfileLogin
    static let height: CGFloat = 112

    private var tone: Color {
        if login.error != nil || login.login == "missing" { return Tone.blocked }
        if !(login.warnings ?? []).isEmpty || !login.behind.isEmpty { return Tone.blocked }
        return Tone.done
    }

    private var line: String {
        if let e = login.error { return e }
        var parts: [String] = [login.here == "holder" ? "Kept fresh by this Mac" : "Kept fresh by \(login.holder)"]
        if let t = login.expires { parts.append("token \(Self.left(t))") }
        if let t = login.loginEnds { parts.append("sign-in ends in \(Self.days(t))") }
        return parts.joined(separator: " · ")
    }

    static func left(_ ms: Double) -> String {
        let s = ms / 1000 - Date().timeIntervalSince1970
        if s <= 0 { return "expired" }
        if s < 3600 { return "\(Int(s / 60))m left" }
        if s < 86400 * 2 { return "\(Int(s / 3600))h left" }
        return "\(Int(s / 86400))d left"
    }

    static func days(_ ms: Double) -> String {
        let d = Int((ms / 1000 - Date().timeIntervalSince1970) / 86400)
        return d <= 0 ? "under a day" : d == 1 ? "1 day" : "\(d) days"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HarnessLogo(harness: login.harness, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        Text(login.harness).font(.system(size: 13, weight: .semibold))
                        Text("[\(login.name)]").font(.system(size: 13, weight: .semibold)).foregroundStyle(HarnessLook.tint(login.harness))
                    }
                    // The dot beside the first line, however many lines the status takes.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Circle().fill(tone).frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                        Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    }
                }
                Spacer(minLength: 0)
            }
            ForEach(login.warnings ?? [], id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(Tone.blocked).lineLimit(1)
            }
            Spacer(minLength: 0)
            FlowChips(chips: chips)
        }
        .padding(11)
        // Every card the same size, whatever it holds: two lines of status, two of machines.
        .frame(maxWidth: .infinity, minHeight: LoginCard.height, maxHeight: LoginCard.height, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    private var chips: [Chip] {
        // (Who keeps it is in the status line: these are where it is current.)
        var xs: [Chip] = []
        xs += login.current.map { Chip(text: $0, symbol: "checkmark", tint: Tone.done) }
        xs += login.behind.map { Chip(text: $0, symbol: "arrow.triangle.2.circlepath", tint: Tone.blocked) }
        return xs
    }
}

private struct Chip: Hashable {
    let text: String
    let symbol: String
    let tint: Color
}

/// Small capsules that wrap onto more lines.
private struct FlowChips: View {
    let chips: [Chip]
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(chips, id: \.self) { c in
                HStack(spacing: 3) {
                    Image(systemName: c.symbol).font(.system(size: 8.5, weight: .bold))
                    Text(c.text).font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(c.tint)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(c.tint.opacity(0.13), in: Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > 0, x + d.width > width { x = 0; y += row + spacing; row = 0 }
            x += d.width + spacing
            row = max(row, d.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + d.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(d))
            x += d.width + spacing
            row = max(row, d.height)
        }
    }
}

/// A machine and, per harness it has profiles for, the one a bare agent starts in.
private struct PlaceRow: View {
    static let pickerWidth: CGFloat = 146
    @ObservedObject private var model = ProfilesModel.shared
    let place: ProfilesModel.Place
    let symbol: String

    private var harnesses: [String] {
        ProfilesModel.harnesses.filter { !model.names($0, on: place).isEmpty }
    }

    var body: some View {
        // Side by side when the pane is wide enough, else the pickers under the name;
        // the name and its state never wrap.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                header
                Spacer(minLength: 8)
                pickers
            }
            VStack(alignment: .leading, spacing: 8) {
                header
                HStack(spacing: 8) { pickers }
            }
        }
        .padding(.vertical, 3)
        .opacity(place.connected ? 1 : 0.55)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            IconTile(symbol: symbol, tint: place.name.isEmpty ? Color(red: 0.36, green: 0.39, blue: 0.47) : Tone.remote, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(place.title).font(Type.title).lineLimit(1).fixedSize()
                HStack(spacing: 4) {
                    Circle().fill(place.connected ? Tone.done : Color.secondary).frame(width: 5, height: 5)
                    Text(place.name.isEmpty ? "This Mac" : place.connected ? (place.read ? "Connected" : "Reading…") : "Away: its defaults show once it's back")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var pickers: some View {
        if place.read && harnesses.isEmpty {
            Text("No profiles there yet").font(Type.meta).foregroundStyle(.secondary)
        }
        ForEach(harnesses, id: \.self) { h in picker(h) }
    }

    private func picker(_ h: String) -> some View {
        let current = place.defaults[h] ?? ""
        let busy = model.busy.contains(model.key(place, h))
        return Menu {
            Section(h) {
                Button { model.setDefault(place, harness: h, to: "") } label: {
                    if current.isEmpty { Label("Your own", systemImage: "checkmark") } else { Text("Your own") }
                }
                ForEach(model.names(h, on: place), id: \.self) { n in
                    Button { model.setDefault(place, harness: h, to: n) } label: {
                        if n == current { Label(n, systemImage: "checkmark") } else { Text(n) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                HarnessLogo(harness: h, size: 14, tile: false)
                Text(h).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                Text(current.isEmpty ? "own" : current).font(.system(size: 11, weight: current.isEmpty ? .regular : .bold)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(current.isEmpty ? Color.secondary : HarnessLook.tint(h))
                Spacer(minLength: 2)
                if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .frame(width: PlaceRow.pickerWidth)
            .background(HarnessLook.tint(h).opacity(current.isEmpty ? 0.06 : 0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(HarnessLook.tint(h).opacity(current.isEmpty ? 0.15 : 0.35), lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!place.connected || busy)
        .help(current.isEmpty ? "A bare \(h) here uses your own login" : "A bare \(h) here starts as \(h)[\(current)]")
    }
}
