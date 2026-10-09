import Foundation
import Security

// User settings (UserDefaults) plus the two secrets: the daemon token (a file
// only this user can read) and an optional Jev API key (Keychain).

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var roots: String { didSet { d.set(roots, forKey: "roots") } }
    @Published var harness: String { didSet { d.set(harness, forKey: "harness") } }
    @Published var threshold: Int { didSet { d.set(threshold, forKey: "threshold") } }
    @Published var undoMs: Int { didSet { d.set(undoMs, forKey: "undoMs") } }
    @Published var port: Int { didSet { d.set(port, forKey: "port") } }
    @Published var remote: Bool { didSet { d.set(remote, forKey: "remote") } }
    @Published var jevProvider: String { didSet { d.set(jevProvider, forKey: "jevProvider") } }
    @Published var jevCredentialCommand: String { didSet { d.set(jevCredentialCommand, forKey: "jevCredentialCommand") } }
    @Published var herdrSession: String { didSet { d.set(herdrSession, forKey: "herdrSession") } }
    @Published var showStrip: Bool { didSet { d.set(showStrip, forKey: "showStrip") } }
    /// Keep the rail on screen instead of revealing it at the edge.
    @Published var railAlways: Bool { didSet { d.set(railAlways, forKey: "railAlways") } }
    /// Let a new question surface at the edge on its own for a few seconds.
    @Published var surfaceQuestions: Bool { didSet { d.set(surfaceQuestions, forKey: "surfaceQuestions") } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    /// A regular app (Dock, ⌘Tab, menu bar) rather than menu-bar only.
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }

    private init() {
        roots = d.string(forKey: "roots") ?? (NSHomeDirectory() + "/VCS")
        harness = d.string(forKey: "harness") ?? "claude"
        threshold = d.object(forKey: "threshold") as? Int ?? 6000
        undoMs = d.object(forKey: "undoMs") as? Int ?? 2000
        port = d.object(forKey: "port") as? Int ?? 47823
        remote = d.bool(forKey: "remote")
        jevProvider = d.string(forKey: "jevProvider") ?? "typesafe"
        jevCredentialCommand = d.string(forKey: "jevCredentialCommand") ?? ""
        herdrSession = d.string(forKey: "herdrSession") ?? ""
        showStrip = d.object(forKey: "showStrip") as? Bool ?? true
        railAlways = d.bool(forKey: "railAlways")
        surfaceQuestions = d.object(forKey: "surfaceQuestions") as? Bool ?? true
        onboarded = d.bool(forKey: "onboarded")
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
    }

    static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

    static func rotateToken() {
        cachedToken = nil
        try? FileManager.default.removeItem(at: supportDir.appendingPathComponent("token"))
    }

    // Jev API key in the Keychain (used when no credential command is set).
    private static let service = "dev.reflex.jev"

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
