import AppKit
import SwiftUI

// "Open in": a session in herdr, or its folder in Finder, a terminal or an
// editor — whichever of them are installed. The button opens the last one
// you chose; its menu lists every one and remembers the choice.

struct OpenTarget: Identifiable, Hashable {
    enum Kind { case herdr, finder, terminal, editor }
    /// "herdr", "finder", or the app's bundle id.
    let id: String
    let name: String
    let kind: Kind
    /// The app, for its icon and to open with.
    let app: URL?
}

@MainActor
enum OpenIn {
    /// Terminals that open a new window in a folder they're handed.
    private static let terminals = [
        ("com.mitchellh.ghostty", "Ghostty"), ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm"), ("dev.warp.Warp-Stable", "Warp"),
    ]
    private static let editors = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"), ("com.microsoft.VSCode", "Visual Studio Code"),
        ("dev.zed.Zed", "Zed"), ("com.exafunction.windsurf", "Windsurf"), ("com.sublimetext.4", "Sublime Text"),
    ]

    static let herdr = OpenTarget(id: "herdr", name: "herdr", kind: .herdr, app: nil)
    static let finder = OpenTarget(id: "finder", name: "Finder", kind: .finder,
                                   app: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))

    /// Everything installed, in menu order. Looked up once: apps rarely come
    /// and go while Reflex runs, and the menu should open instantly.
    static let installed: [OpenTarget] = {
        func found(_ list: [(String, String)], _ kind: OpenTarget.Kind) -> [OpenTarget] {
            list.compactMap { id, name in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { OpenTarget(id: id, name: name, kind: kind, app: $0) }
            }
        }
        return [herdr, finder] + found(terminals, .terminal) + found(editors, .editor)
    }()

    /// The one the button opens: the last choice, if it's still installed.
    static var preferred: OpenTarget {
        installed.first { $0.id == Settings.shared.openIn } ?? herdr
    }

    static func icon(_ t: OpenTarget) -> NSImage {
        let image = t.app.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)!
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    static func open(_ t: OpenTarget, agent: AgentInfo?, pane: String, remember: Bool = false) {
        if remember { Settings.shared.openIn = t.id }
        // Another machine's folder: a shell there in a terminal here, or an
        // editor over ssh.
        if t.kind != .herdr, let a = agent, a.remote, !a.cwd.isEmpty {
            return openRemote(t, a)
        }
        guard t.kind != .herdr, let cwd = agent?.cwd, !cwd.isEmpty else {
            HerdrWindow.reveal(pane: pane)
            return
        }
        let folder = URL(fileURLWithPath: cwd, isDirectory: true)
        switch t.kind {
        case .herdr:
            break
        case .finder:
            NSWorkspace.shared.open(folder)
        case .terminal where t.id == "com.mitchellh.ghostty":
            // Ghostty takes its working directory as an argument, not a document.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", t.app!.path, "--args", "--working-directory=\(cwd)"]
            try? p.run()
        case .terminal, .editor:
            NSWorkspace.shared.open([folder], withApplicationAt: t.app!, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

extension OpenIn {
    /// Editors that open a folder over ssh (`<scheme>://vscode-remote/ssh-remote+host/path`).
    static let sshEditors: [String: String] = [
        "com.microsoft.VSCode": "vscode", "com.todesktop.230313mzl4w4u92": "cursor", "com.exafunction.windsurf": "windsurf",
    ]

    /// The machine's ssh host, when herdr-core reaches it with plain ssh
    /// (not a command like `boat ssh`).
    static func sshHost(_ machine: String) -> String? {
        guard let m = CoreMachines.known.first(where: { $0.name == machine }), !m.target.contains(" ") else { return nil }
        return m.target
    }

    /// What opens another machine's folder: terminals always (a shell there,
    /// through herdr-core), editors that speak ssh when it's an ssh host.
    static func remoteTargets(_ machine: String) -> [OpenTarget] {
        installed.filter { $0.kind == .terminal || ($0.kind == .editor && sshEditors[$0.id] != nil && sshHost(machine) != nil) }
    }

    static func openRemote(_ t: OpenTarget, _ a: AgentInfo) {
        if t.kind == .editor, let scheme = sshEditors[t.id], let host = sshHost(a.machine) {
            let path = a.cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? a.cwd
            if let url = URL(string: "\(scheme)://vscode-remote/ssh-remote+\(host)\(path)") { NSWorkspace.shared.open(url) }
            return
        }
        guard t.kind == .terminal, t.app != nil else { return HerdrWindow.reveal(pane: a.pane) }
        openShell(on: a.machine, cwd: a.cwd, with: t)
    }

    /// The terminal app you use (the last one chosen, else the first installed).
    static var terminal: OpenTarget? {
        let ts = installed.filter { $0.kind == .terminal }
        return ts.first { $0.id == Settings.shared.openIn } ?? ts.first
    }

    /// A login shell on `machine` in `cwd`, in a terminal app here: a herdr-core
    /// terminal there (gone when the shell exits) with the app attached to it.
    static func openShell(on machine: String, cwd: String, with target: OpenTarget? = nil) {
        guard let t = target ?? terminal, let app = t.app else { return }
        let env = HerdrCore.environment()
        guard let hc = HerdrCore.binary(env) else { return }
        Task.detached {
            // A login shell in its folder there, gone when it exits…
            let p = Process()
            p.executableURL = URL(fileURLWithPath: hc)
            // (No folder: its home.)
            p.arguments = ["run", "--bg", "--no-parent", "--rm", "--on", machine] + (cwd.isEmpty ? [] : ["--cwd", cwd]) + ["--json", "--",
                           "sh", "-c", "exec \"${SHELL:-/bin/sh}\" -l"]
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let address = j["address"] as? String else { return }
            // …and the terminal app on it.
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("reflex-\(address.replacingOccurrences(of: "/", with: "-")).command")
            let session = env["HC_SESSION"].map { "export HC_SESSION='\($0)'\n" } ?? ""
            try? "#!/bin/sh\n\(session)exec '\(hc)' attach '\(address)'\n".write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = t.id == "com.mitchellh.ghostty" ? ["-na", app.path, "--args", "-e", script.path] : ["-a", app.path, script.path]
            try? open.run()
        }
    }
}

/// The menu's items: the session in herdr, then its folder everywhere else.
struct OpenInItems: View {
    var agent: AgentInfo?
    var pane: String

    var body: some View {
        Button { OpenIn.open(OpenIn.herdr, agent: agent, pane: pane, remember: true) } label: {
            Label { Text(HerdrCore.isCore(pane) ? "Open Terminal" : "Show in herdr") } icon: { Image(systemName: "arrow.up.forward.app") }
        }
        if let a = agent, a.remote, !a.cwd.isEmpty {
            Section("Open \(a.folder) on \(a.machine) in") {
                ForEach(OpenIn.remoteTargets(a.machine)) { t in
                    Button { OpenIn.open(t, agent: agent, pane: pane, remember: true) } label: {
                        Label { Text(t.name) } icon: { Image(nsImage: OpenIn.icon(t)) }
                    }
                }
            }
        } else if agent?.cwd.isEmpty == false {
            Section(agent.map { "Open \($0.folder) in" } ?? "Open in") {
                ForEach(OpenIn.installed.filter { $0.kind != .herdr }) { t in
                    Button { OpenIn.open(t, agent: agent, pane: pane, remember: true) } label: {
                        Label { Text(t.name) } icon: { Image(nsImage: OpenIn.icon(t)) }
                    }
                }
            }
        }
    }
}

/// A split button: the icon opens the preferred target, the chevron lists them all.
struct OpenInButton: View {
    var agent: AgentInfo?
    var pane: String
    var tint: Color
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        // (On another machine: the preferred one when it can open there.)
        let t = agent.map { a in a.remote && !OpenIn.remoteTargets(a.machine).contains(OpenIn.preferred) ? OpenIn.herdr : OpenIn.preferred } ?? OpenIn.preferred
        Menu {
            OpenInItems(agent: agent, pane: pane)
        } label: {
            if t.kind == .herdr { Image(systemName: "arrow.up.forward.app") } else { Image(nsImage: OpenIn.icon(t)) }
        } primaryAction: {
            OpenIn.open(t, agent: agent, pane: pane)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .tint(tint)
        .foregroundStyle(tint)
        .help(t.kind == .herdr ? (HerdrCore.isCore(pane) ? "Open its terminal — the arrow lists more" : "Show in herdr — the arrow lists more") : "Open \(agent?.folder ?? "the folder") in \(t.name) — the arrow lists more")
        .id(settings.openIn)
    }
}
