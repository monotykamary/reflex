import AppKit
import Foundation
import Security

// User settings (UserDefaults) plus the two secrets: the daemon token (a file
// only this user can read) and an optional Jev API key (Keychain).

final class Settings: ObservableObject {
    static let shared = Settings()

    /// A separate profile (REFLEX_PROFILE=<folder>): its own settings, support
    /// folder, Keychain entry and port — Reflex as a new user meets it, on the
    /// same Mac, without touching the real one. For testing first runs.
    static let profile: String? = ProcessInfo.processInfo.environment["REFLEX_PROFILE"]
    static let profileKey: String? = profile.map { "profile" + $0.replacingOccurrences(of: "/", with: ".") }
    private let d = Settings.profileKey.flatMap { UserDefaults(suiteName: "dev.reflex." + $0) } ?? .standard

    @Published var roots: String { didSet { d.set(roots, forKey: "roots") } }
    @Published var harness: String { didSet { d.set(harness, forKey: "harness") } }
    /// Saying this asks for a new project folder (rare by design; see the Ask bar).
    @Published var newKeyword: String { didSet { d.set(newKeyword, forKey: "newKeyword") } }
    /// Where new project folders are made. Empty: the first project root.
    @Published var newRoot: String { didSet { d.set(newRoot, forKey: "newRoot") } }
    /// Single folders added from the Ask bar that sit outside the roots.
    @Published var extraFolders: [String] { didSet { d.set(extraFolders, forKey: "extraFolders"); Settings.writeFolders(extraFolders) } }
    @Published var port: Int { didSet { d.set(port, forKey: "port") } }
    @Published var remote: Bool { didSet { d.set(remote, forKey: "remote") } }
    /// Without Tailscale, the phone remote may use this Wi-Fi only when you
    /// say so: plain HTTP there, and its token can type into your agents.
    @Published var remoteLAN: Bool { didSet { d.set(remoteLAN, forKey: "remoteLAN") } }
    @Published var jevProvider: String { didSet { d.set(jevProvider, forKey: "jevProvider") } }
    @Published var jevCredentialCommand: String { didSet { d.set(jevCredentialCommand, forKey: "jevCredentialCommand") } }
    @Published var herdrSession: String { didSet { d.set(herdrSession, forKey: "herdrSession") } }
    @Published var showStrip: Bool { didSet { d.set(showStrip, forKey: "showStrip") } }
    /// Keep the rail on screen instead of revealing it at the edge.
    @Published var railAlways: Bool { didSet { d.set(railAlways, forKey: "railAlways") } }
    /// Let a new question surface at the edge on its own for a few seconds.
    @Published var surfaceQuestions: Bool { didSet { d.set(surfaceQuestions, forKey: "surfaceQuestions") } }
    /// How long the pointer rests on an empty edge before the rail opens.
    @Published var edgeDelay: Double { didSet { d.set(edgeDelay, forKey: "edgeDelay") } }
    /// Keep awake: "off", "agents" (while any agent works) or "always".
    @Published var awakeMode: String { didSet { d.set(awakeMode, forKey: "awakeMode") } }
    /// Keep the display on too, not only the Mac.
    @Published var awakeDisplay: Bool { didSet { d.set(awakeDisplay, forKey: "awakeDisplay") } }
    /// Where "Open in" goes first: "herdr", "finder" or an app's bundle id.
    @Published var openIn: String { didSet { d.set(openIn, forKey: "openIn") } }
    /// On battery at or below this percentage, let the Mac sleep (0: never).
    @Published var awakeBattery: Int { didSet { d.set(awakeBattery, forKey: "awakeBattery") } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    /// A regular app (Dock, ⌘Tab, menu bar) rather than menu-bar only.
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    /// "system", "light" or "dark": Reflex's surfaces in either of Raycast's tones.
    @Published var appearance: String { didSet { d.set(appearance, forKey: "appearance") } }

    private init() {
        roots = d.string(forKey: "roots") ?? (NSHomeDirectory() + "/VCS")
        harness = d.string(forKey: "harness") ?? "claude"
        newKeyword = d.string(forKey: "newKeyword") ?? "new project"
        newRoot = d.string(forKey: "newRoot") ?? ""
        extraFolders = d.stringArray(forKey: "extraFolders") ?? []
        port = d.object(forKey: "port") as? Int ?? (Settings.profile == nil ? 47823 : 47851)
        remote = d.bool(forKey: "remote")
        remoteLAN = d.bool(forKey: "remoteLAN")
        jevProvider = d.string(forKey: "jevProvider") ?? "typesafe"
        jevCredentialCommand = d.string(forKey: "jevCredentialCommand") ?? ""
        herdrSession = d.string(forKey: "herdrSession") ?? ""
        showStrip = d.object(forKey: "showStrip") as? Bool ?? true
        railAlways = d.bool(forKey: "railAlways")
        surfaceQuestions = d.object(forKey: "surfaceQuestions") as? Bool ?? true
        edgeDelay = d.object(forKey: "edgeDelay") as? Double ?? 0.5
        awakeMode = d.string(forKey: "awakeMode") ?? "agents"
        awakeDisplay = d.object(forKey: "awakeDisplay") as? Bool ?? false
        openIn = d.string(forKey: "openIn") ?? "herdr"
        awakeBattery = d.object(forKey: "awakeBattery") as? Int ?? 20
        onboarded = d.bool(forKey: "onboarded")
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
        appearance = d.string(forKey: "appearance") ?? "system"
        Settings.writeFolders(extraFolders)
    }

    /// Light, dark, or whatever macOS is using. (Agent terminals keep their
    /// own theme's appearance.)
    @MainActor func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    var rootList: [String] { roots.split(separator: ":").map(String.init) }

    /// Where a new project folder goes.
    var newFolderParent: String {
        newRoot.isEmpty ? (rootList.first ?? NSHomeDirectory()) : newRoot
    }

    /// Is this folder already inside one of the roots (so the index finds it)?
    func covers(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        return rootList.contains { p == $0 || p.hasPrefix(($0 as NSString).standardizingPath + "/") } || extraFolders.contains(p)
    }

    /// Add a folder chosen in the Ask bar to the projects list when the
    /// roots don't already cover it, then re-index.
    func addFolder(_ path: String) {
        let p = (path as NSString).standardizingPath
        guard !covers(p) else { return }
        extraFolders.append(p)
        Task { await Client.local.reindex() }
    }

    static var foldersFile: URL { supportDir.appendingPathComponent("folders.txt") }

    static func writeFolders(_ fs: [String]) {
        try? (fs.joined(separator: "\n") + "\n").write(to: foldersFile, atomically: true, encoding: .utf8)
    }

    static var supportDir: URL {
        let url = profile.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Reflex", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var cachedToken: String?

    /// The daemon's bearer token, created once and kept 0600.
    static var token: String {
        if let t = cachedToken { return t }
        let t = loadToken()
        cachedToken = t
        return t
    }

    private static func loadToken() -> String {
        let url = supportDir.appendingPathComponent("token")
        if let t = try? String(contentsOf: url, encoding: .utf8), !t.isEmpty {
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: url.path, contents: Data(t.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return t
    }

    /// This launch's own token, for the Mac app alone (never leaves memory).
    static let sessionToken: String = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()

    /// What reflexd accepts: the phone link's token only while the phone
    /// remote is on — otherwise a phone that still has the link (which a
    /// userspace tailscaled can still deliver to localhost) gets nowhere.
    static var daemonToken: String { Settings.shared.remote ? token : sessionToken }

    static func rotateToken() {
        cachedToken = nil
        try? FileManager.default.removeItem(at: supportDir.appendingPathComponent("token"))
    }

    // Jev API key in the Keychain (used when no credential command is set).
    private static let service = "dev.reflex.jev" + (profileKey.map { "." + $0 } ?? "")

    static var jevKey: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(q as CFDictionary)
            guard let v = newValue, !v.isEmpty else { return }
            var add = q
            add[kSecValueData as String] = Data(v.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// A credential command that reads pi's stored TypeSafe key, when pi has one,
    /// so the key never has to be copied.
    static var piCredentialCommand: String? {
        let auth = NSHomeDirectory() + "/.pi/agent/auth.json"
        guard let data = FileManager.default.contents(atPath: auth),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["typesafe"] != nil else { return nil }
        let cmd = ["python3", "-I", "-c",
                   "import json,os;print(json.load(open(os.path.expanduser('~/.pi/agent/auth.json')))['typesafe']['key'])"]
        guard let out = try? JSONSerialization.data(withJSONObject: cmd) else { return nil }
        return String(data: out, encoding: .utf8)
    }
}
