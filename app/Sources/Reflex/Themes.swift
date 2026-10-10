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

    /// Which slot the terminal uses: the appearance's, or always one.
    enum Mode: String, CaseIterable { case follow, dark, light }
    enum Slot: String { case dark, light }

    /// The theme in use right now (the dark or light slot, per `mode`).
    @Published private(set) var current: TermTheme
    @Published var darkName: String { didSet { UserDefaults.standard.set(darkName, forKey: "terminalThemeDark"); refresh() } }
    @Published var lightName: String { didSet { UserDefaults.standard.set(lightName, forKey: "terminalThemeLight"); refresh() } }
    /// Picking a theme for one slot picks its sibling for the other.
    @Published var linked: Bool { didSet { UserDefaults.standard.set(linked, forKey: "terminalThemesLinked") } }
    @Published var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "terminalThemeMode"); refresh() } }
    @Published var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "terminalFontSize") } }
    /// A monospaced font family. Geist Mono when it is installed, else SF Mono.
    @Published var fontFamily: String { didSet { UserDefaults.standard.set(fontFamily, forKey: "terminalFont") } }
    @Published private(set) var names: [String] = Themes.listNames()
    /// Light or dark, per theme, learned from its background.
    @Published private(set) var darkness: [String: Bool] = [:]

    private init() {
        let d = UserDefaults.standard
        // Before slots there was one theme: it fills the slot it suits.
        let legacy = d.string(forKey: "terminalTheme").flatMap { Themes.load($0) }
        let dark = d.string(forKey: "terminalThemeDark") ?? (legacy?.isDark == true ? legacy!.name : "TokyoNight")
        let light = d.string(forKey: "terminalThemeLight") ?? (legacy?.isDark == false ? legacy!.name : "TokyoNight Day")
        darkName = dark
        lightName = light
        linked = d.object(forKey: "terminalThemesLinked") as? Bool ?? true
        mode = Mode(rawValue: d.string(forKey: "terminalThemeMode") ?? "") ?? .follow
        fontSize = d.object(forKey: "terminalFontSize") as? Double ?? 12.5
        fontFamily = d.string(forKey: "terminalFont") ?? Themes.defaultFamily
        current = Themes.load(dark) ?? .tokyoNight
        refresh()
    }

    /// The slot in use: the app's appearance when following it.
    var activeSlot: Slot {
        switch mode {
        case .dark: return .dark
        case .light: return .light
        case .follow:
            let a = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return a == .aqua ? .light : .dark
        }
    }

    /// Re-pick the theme for the current appearance (call when it changes).
    func refresh() {
        let name = activeSlot == .dark ? darkName : lightName
        let t = Themes.load(name) ?? (activeSlot == .dark ? .tokyoNight : .tokyoNightDay)
        if t != current { current = t }
    }

    func select(_ name: String, for slot: Slot) {
        if slot == .dark { darkName = name } else { lightName = name }
        guard linked, let other = Themes.sibling(of: name, among: names) else { return }
        if slot == .dark { lightName = other } else { darkName = other }
    }

    /// Set both slots at once (a starter pair).
    func choose(_ pair: Pair) {
        let wasLinked = linked
        linked = false
        darkName = pair.dark
        lightName = pair.light
        linked = wasLinked
    }

    /// Read every theme's background once, off the main thread.
    func learnDarkness() {
        guard darkness.isEmpty else { return }
        let all = names
        Task.detached(priority: .utility) {
            var out: [String: Bool] = [:]
            for n in all { out[n] = Themes.load(n)?.isDark ?? true }
            let learned = out
            await MainActor.run { Themes.shared.darkness = learned }
        }
    }

    func reloadNames() {
        names = Themes.listNames()
        darkness = [:]
        learnDarkness()
    }

    /// Copy Ghostty-format theme files into Reflex's own themes folder.
    func importThemes(_ urls: [URL]) -> [String] {
        let dir = Settings.supportDir.appendingPathComponent("themes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var added: [String] = []
        for u in urls {
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let name = u.deletingPathExtension().lastPathComponent
            guard TermTheme.parse(name: name, text: text) != nil else { continue }
            try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            added.append(name)
        }
        reloadNames()
        return added
    }

    // MARK: Pairs

    struct Pair: Identifiable, Hashable {
        var name: String
        var dark: String
        var light: String
        var id: String { name }
    }

    /// Families that come in both, for one-click starts.
    static let starterPairs: [Pair] = [
        Pair(name: "Tokyo Night", dark: "TokyoNight", light: "TokyoNight Day"),
        Pair(name: "Catppuccin", dark: "Catppuccin Mocha", light: "Catppuccin Latte"),
        Pair(name: "Rosé Pine", dark: "Rose Pine", light: "Rose Pine Dawn"),
        Pair(name: "Kanagawa", dark: "Kanagawa Wave", light: "Kanagawa Lotus"),
        Pair(name: "GitHub", dark: "GitHub Dark Default", light: "GitHub Light Default"),
        Pair(name: "Gruvbox", dark: "Gruvbox Dark", light: "Gruvbox Light"),
        Pair(name: "Everforest", dark: "Everforest Dark Hard", light: "Everforest Light Med"),
        Pair(name: "Nord", dark: "Nord", light: "Nord Light"),
        Pair(name: "Ayu", dark: "Ayu", light: "Ayu Light"),
        Pair(name: "Flexoki", dark: "Flexoki Dark", light: "Flexoki Light"),
        Pair(name: "Night Owl", dark: "Night Owl", light: "Light Owl"),
        Pair(name: "Raycast", dark: "Raycast Dark", light: "Raycast Light"),
    ]

    /// Known siblings that no rename rule finds.
    private static let siblings: [String: String] = [
        "TokyoNight": "TokyoNight Day", "TokyoNight Storm": "TokyoNight Day", "TokyoNight Moon": "TokyoNight Day",
        "TokyoNight Night": "TokyoNight Day",
        "Catppuccin Mocha": "Catppuccin Latte", "Catppuccin Frappe": "Catppuccin Latte", "Catppuccin Macchiato": "Catppuccin Latte",
        "Rose Pine": "Rose Pine Dawn", "Rose Pine Moon": "Rose Pine Dawn",
        "Kanagawa Wave": "Kanagawa Lotus", "Kanagawa Dragon": "Kanagawa Lotus",
        "Nightfox": "Dayfox", "Duskfox": "Dawnfox", "Carbonfox": "Dayfox", "Terafox": "Dayfox", "Nordfox": "Dawnfox",
        "Ayu": "Ayu Light", "Ayu Mirage": "Ayu Light", "Nord": "Nord Light", "Onenord": "Onenord Light",
        "Night Owl": "Light Owl", "Everforest Dark Hard": "Everforest Light Med",
        "GitHub Dark": "GitHub Light Default", "GitHub Dark Default": "GitHub Light Default", "GitHub Dark Dimmed": "GitHub Light Default",
        "GitHub Dark Colorblind": "GitHub Light Colorblind", "GitHub Dark High Contrast": "GitHub Light High Contrast",
        "Monokai Pro": "Monokai Pro Light", "Monokai Pro Machine": "Monokai Pro Light", "Monokai Pro Octagon": "Monokai Pro Light",
        "Monokai Pro Ristretto": "Monokai Pro Light Sun", "Monokai Pro Spectrum": "Monokai Pro Light",
        "Apple System Colors": "Apple System Colors Light", "Atom One Dark": "Atom One Light", "Atom": "Atom One Light",
        "Gruvbox Material": "Gruvbox Material Light", "Iceberg Dark": "Iceberg Light", "One Half Dark": "One Half Light",
        "One Double Dark": "One Double Light", "Xcode Dark": "Xcode Light", "Xcode Dark hc": "Xcode Light hc",
        "iTerm2 Solarized Dark": "iTerm2 Solarized Light", "iTerm2 Dark Background": "iTerm2 Light Background",
    ]

    /// The other half of a light/dark pair, when one exists among `names`.
    static func sibling(of name: String, among names: [String]) -> String? {
        let have = Set(names)
        if let s = siblings[name], have.contains(s) { return s }
        if let s = siblings.first(where: { $0.value == name })?.key, have.contains(s) { return s }
        let swaps = [("Dark", "Light"), ("dark", "light"), ("Night", "Day"), ("night", "day"),
                     ("Mocha", "Latte"), ("Black", "White")]
        for (a, b) in swaps {
            for (from, to) in [(a, b), (b, a)] where name.contains(from) {
                let candidate = name.replacingOccurrences(of: from, with: to)
                if candidate != name, have.contains(candidate) { return candidate }
            }
        }
        return nil
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

    /// Ghostty's themes, wherever Ghostty is installed, plus user themes.
    nonisolated static var directories: [URL] {
        var dirs: [URL] = []
        for app in ["/Applications/Ghostty.app", NSHomeDirectory() + "/Applications/Ghostty.app"] {
            dirs.append(URL(fileURLWithPath: app + "/Contents/Resources/ghostty/themes"))
        }
        dirs.append(URL(fileURLWithPath: NSHomeDirectory() + "/.config/ghostty/themes"))
        dirs.append(Settings.supportDir.appendingPathComponent("themes"))
        return dirs
    }

    nonisolated static func listNames() -> [String] {
        var names = Set(TermTheme.builtIn.map(\.name))
        for d in directories {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where !f.hasPrefix(".") {
                names.insert(f)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated static func load(_ name: String) -> TermTheme? {
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
