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

/// The menu's items: the session in herdr, then its folder everywhere else.
struct OpenInItems: View {
    var agent: AgentInfo?
    var pane: String

    var body: some View {
        Button { OpenIn.open(OpenIn.herdr, agent: agent, pane: pane, remember: true) } label: {
            Label { Text("Show in herdr") } icon: { Image(systemName: "arrow.up.forward.app") }
        }
        if agent?.cwd.isEmpty == false {
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
        let t = OpenIn.preferred
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
        .help(t.kind == .herdr ? "Show in herdr — the arrow lists more" : "Open \(agent?.folder ?? "the folder") in \(t.name) — the arrow lists more")
        .id(settings.openIn)
    }
}
