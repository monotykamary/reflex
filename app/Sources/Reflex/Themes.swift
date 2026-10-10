import AppKit
import SwiftUI

// Terminal themes. Any theme in Ghostty's format works (`palette = N=#rrggbb`,
// `background`, `foreground`, `cursor-color`, `selection-background`): Reflex
// lists every theme Ghostty ships when Ghostty is installed, plus a built-in
// Tokyo Night family so it works without it. Tokyo Night is the default.

struct TermTheme: Equatable {
    var name: String
    var background: String
    var foreground: String
    var cursor: String
    var selection: String
    var palette: [String]

    static func parse(name: String, text: String) -> TermTheme? {
        var t = TermTheme(name: name, background: "#1a1b26", foreground: "#c0caf5", cursor: "", selection: "#33467c",
                          palette: TermTheme.tokyoNight.palette)
        var seen = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": t.background = hex(value); seen = true
            case "foreground": t.foreground = hex(value)
            case "cursor-color": t.cursor = hex(value)
            case "selection-background": t.selection = hex(value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let i = Int(parts[0].trimmingCharacters(in: .whitespaces)), (0..<16).contains(i) {
                    t.palette[i] = hex(String(parts[1]))
                }
            default: break
            }
        }
        if t.cursor.isEmpty { t.cursor = t.foreground }
        return seen ? t : nil
    }

    private static func hex(_ v: String) -> String {
        let s = v.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("#") ? s : "#" + s
    }

    var isDark: Bool { NSColor(hex: background).luminance < 0.5 }

    static let tokyoNight = TermTheme(
        name: "TokyoNight", background: "#1a1b26", foreground: "#c0caf5", cursor: "#c0caf5", selection: "#33467c",
        palette: ["#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                  "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"])
    static let tokyoNightStorm = TermTheme(
        name: "TokyoNight Storm", background: "#24283b", foreground: "#c0caf5", cursor: "#c0caf5", selection: "#364a82",
        palette: ["#1d202f", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                  "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"])
    static let tokyoNightMoon = TermTheme(
        name: "TokyoNight Moon", background: "#222436", foreground: "#c8d3f5", cursor: "#c8d3f5", selection: "#2d3f76",
        palette: ["#1b1d2b", "#ff757f", "#c3e88d", "#ffc777", "#82aaff", "#c099ff", "#86e1fc", "#828bb8",
                  "#444a73", "#ff757f", "#c3e88d", "#ffc777", "#82aaff", "#c099ff", "#86e1fc", "#c8d3f5"])
    static let tokyoNightDay = TermTheme(
        name: "TokyoNight Day", background: "#e1e2e7", foreground: "#3760bf", cursor: "#3760bf", selection: "#99a7df",
        palette: ["#e9e9ed", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#6172b0",
                  "#a1a6c5", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#3760bf"])

    static let builtIn = [tokyoNight, tokyoNightStorm, tokyoNightMoon, tokyoNightDay]
}

@MainActor
final class Themes: ObservableObject {
    static let shared = Themes()

    @Published var current: TermTheme
    @Published var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "terminalFontSize") } }
    /// A monospaced font family. Geist Mono when it is installed, else SF Mono.
    @Published var fontFamily: String { didSet { UserDefaults.standard.set(fontFamily, forKey: "terminalFont") } }
    private(set) lazy var names: [String] = Themes.listNames()

    private init() {
        let name = UserDefaults.standard.string(forKey: "terminalTheme") ?? "TokyoNight"
        current = Themes.load(name) ?? .tokyoNight
        fontSize = UserDefaults.standard.object(forKey: "terminalFontSize") as? Double ?? 12.5
        fontFamily = UserDefaults.standard.string(forKey: "terminalFont") ?? Themes.defaultFamily
    }

    static var defaultFamily: String {
        NSFontManager.shared.availableMembers(ofFontFamily: "Geist Mono") != nil ? "Geist Mono" : "SF Mono"
    }

    /// Installed monospaced families, for the font picker.
    static let monospacedFamilies: [String] = {
        let mono = NSFontDescriptor(fontAttributes: [.traits: [NSFontDescriptor.TraitKey.symbolic: NSFontDescriptor.SymbolicTraits.monoSpace.rawValue]])
        var names = Set(mono.matchingFontDescriptors(withMandatoryKeys: [.traits])
            .compactMap { $0.object(forKey: .family) as? String }
            .filter { !$0.hasPrefix(".") })
        names.insert("SF Mono")
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// The terminal font at a size, falling back to the system monospace.
    static func font(_ family: String, size: Double) -> NSFont {
        if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) { return f }
        if family == "SF Mono", let f = NSFont(name: "SFMono-Regular", size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func select(_ name: String) {
        guard let t = Themes.load(name) else { return }
        current = t
        UserDefaults.standard.set(name, forKey: "terminalTheme")
    }

    /// Ghostty's themes, wherever Ghostty is installed, plus user themes.
    static var directories: [URL] {
        var dirs: [URL] = []
        for app in ["/Applications/Ghostty.app", NSHomeDirectory() + "/Applications/Ghostty.app"] {
            dirs.append(URL(fileURLWithPath: app + "/Contents/Resources/ghostty/themes"))
        }
        dirs.append(URL(fileURLWithPath: NSHomeDirectory() + "/.config/ghostty/themes"))
        dirs.append(Settings.supportDir.appendingPathComponent("themes"))
        return dirs
    }

    static func listNames() -> [String] {
        var names = Set(TermTheme.builtIn.map(\.name))
        for d in directories {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where !f.hasPrefix(".") {
                names.insert(f)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func load(_ name: String) -> TermTheme? {
        for d in directories.reversed() {
            let url = d.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8), let t = TermTheme.parse(name: name, text: text) {
                return t
            }
        }
        return TermTheme.builtIn.first { $0.name == name }
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s.prefix(6), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}
