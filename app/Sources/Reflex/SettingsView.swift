import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var daemon = Daemon.shared
    @ObservedObject var store = Store.shared
    @State private var jevKey = ""
    @State private var setup = Setup.check()
    @State private var tab = ProcessInfo.processInfo.environment["REFLEX_SETTINGS_TAB"] ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }.tag("terminal")
            routing.tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }.tag("routing")
            phone.tabItem { Label("Phone", systemImage: "iphone") }.tag("phone")
            status.tabItem { Label("Setup", systemImage: "checklist") }.tag("setup")
        }
        .padding(20)
        .frame(width: 560, height: 470)
    }

    private var general: some View {
        Form {
            TextField("Project roots", text: $s.roots, prompt: Text("~/VCS:~/Projects"))
            Text("Colon-separated folders scanned for repositories new sessions can start in.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Default agent for new sessions", selection: $s.harness) {
                ForEach(["claude", "codex", "pi", "grok", "opencode", "amp", "gemini"], id: \.self) { Text($0) }
            }
            Stepper("Undo window: \(String(format: "%.1f", Double(s.undoMs) / 1000))s", value: $s.undoMs, in: 0...10000, step: 500)
            TextField("Herdr session (empty = default)", text: $s.herdrSession)
            Toggle("Show the rail", isOn: $s.showStrip)
            Toggle("Keep the rail visible (otherwise rest on the right edge for half a second)", isOn: $s.railAlways)
            Toggle("Surface new questions at the edge", isOn: $s.surfaceQuestions)
            HStack {
                Button("Apply & restart reflexd") { daemon.restart() }
                Button("Rebuild folder index") { Task { await Client.local.reindex() } }
                Spacer()
                Text(daemon.running ? "reflexd running" : "reflexd stopped")
                    .foregroundStyle(daemon.running ? .green : .orange).font(.caption)
            }
            if let e = daemon.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
        }
    }

    private var routing: some View {
        Form {
            Picker("Jev provider", selection: $s.jevProvider) {
                ForEach(["typesafe", "openrouter", "vercel"], id: \.self) { Text($0) }
            }
            SecureField("API key (stored in Keychain)", text: $jevKey)
                .onSubmit { Settings.jevKey = jevKey; jevKey = ""; daemon.restart() }
            TextField("…or credential command (JSON argv)", text: $s.jevCredentialCommand)
                .font(.system(.body, design: .monospaced))
            if let pi = Settings.piCredentialCommand, s.jevCredentialCommand.isEmpty {
                Button("Use the TypeSafe key pi already has") { s.jevCredentialCommand = pi; daemon.restart() }
            }
            Slider(value: Binding(get: { Double(s.threshold) }, set: { s.threshold = Int($0) }), in: 3000...9500, step: 250) {
                Text("Confidence to act: \(s.threshold / 100)%")
            }
            Text("Below this, Reflex asks you to pick (1/2/3) instead of routing.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Apply & restart reflexd") { daemon.restart() }
        }
    }

    private var phone: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Allow the phone remote (listen on the network)", isOn: Binding(
                get: { s.remote }, set: { s.remote = $0; daemon.restart() }))
            if s.remote {
                let url = Remote.url(port: s.port, token: Settings.token)
                HStack(alignment: .top, spacing: 16) {
                    if let img = Remote.qr(url) {
                        Image(nsImage: img).interpolation(.none).resizable().frame(width: 180, height: 180)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with your phone's camera, then add the page to your home screen.")
                        Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(Remote.preferredIsTailscale
                             ? "Using your Tailscale address: traffic is encrypted end to end."
                             : "No Tailscale address found: this LAN link is not encrypted. Prefer Tailscale.")
                            .font(.caption).foregroundStyle(Remote.preferredIsTailscale ? Color.secondary : Color.orange)
                        Button("New link (revokes the old one)") { Settings.rotateToken(); daemon.restart() }
                    }
                }
            } else {
                Text("Off: reflexd only listens on this Mac.").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            check(setup.herdr, "herdr installed", fix: "brew install herdr")
            check(setup.jev, "jev-fabric installed", fix: "curl -fsSL https://raw.githubusercontent.com/fabric-runtime/jev-fabric/main/install.sh | sh")
            check(store.state.herdr, "herdr server reachable", fix: "run `herdr` in a terminal")
            check(DoubleOption.trusted, "Accessibility (for ⌥⌥)", fix: nil, action: DoubleOption.requestTrust)
            check(setup.integrations, "herdr agent integrations (session ids for btw forks)",
                  fix: "herdr integration install claude && herdr integration install pi")
            Spacer()
            Button("Check again") { setup = Setup.check() }
        }
    }

    private func check(_ ok: Bool, _ title: String, fix: String?, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !ok, let fix { Text(fix).font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary) }
            }
            Spacer()
            if !ok, let action { Button("Grant…", action: action).controlSize(.small) }
        }
    }
}

struct Setup {
    var herdr = false
    var jev = false
    var integrations = false

    static func check() -> Setup {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
        func which(_ b: String) -> Bool {
            path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(b)") }
        }
        let home = NSHomeDirectory()
        let hooks = [home + "/.claude/hooks/herdr-agent-state.sh", home + "/.pi/agent/extensions/herdr-agent-state.ts"]
        return Setup(herdr: which("herdr"), jev: which("jev-fabric"),
                     integrations: hooks.contains { FileManager.default.fileExists(atPath: $0) })
    }
}

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

/// Pick the terminal theme (every Ghostty theme, plus the built-in Tokyo Night
/// family) and font size. Applies live to every open agent terminal.
struct TerminalSettings: View {
    @ObservedObject var themes = Themes.shared
    @State private var query = ""

    private var names: [String] {
        query.isEmpty ? themes.names : themes.names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search \(themes.names.count) themes", text: $query).textFieldStyle(.roundedBorder)
                Stepper("\(String(format: "%.1f", themes.fontSize)) pt", value: $themes.fontSize, in: 9...20, step: 0.5)
                    .fixedSize()
            }
            ScrollViewReader { proxy in
                List(names, id: \.self) { name in
                    ThemeRow(name: name, selected: name == themes.current.name)
                        .contentShape(Rectangle())
                        .onTapGesture { themes.select(name) }
                        .id(name)
                }
                .listStyle(.inset)
                .onAppear { proxy.scrollTo(themes.current.name, anchor: .center) }
            }
            Text("Themes come from Ghostty when it is installed; drop more Ghostty-format theme files in ~/.config/ghostty/themes.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
