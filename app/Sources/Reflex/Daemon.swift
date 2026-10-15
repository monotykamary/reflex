import Darwin
import Foundation

// Runs reflexd (bundled in Resources, or from the repo in development) and
// keeps it running. The daemon prints one {"ready":...} line, then serves.

@MainActor
final class Daemon: ObservableObject {
    static let shared = Daemon()

    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    private var process: Process?
    private var stopping = false
    private var restarts = 0
    /// REFLEX_PATH (testing a profile): exactly this PATH, e.g. one without herdr.
    private lazy var loginPath: String = ProcessInfo.processInfo.environment["REFLEX_PATH"] ?? Daemon.readLoginPath()

    var baseURL: URL { URL(string: "http://127.0.0.1:\(Settings.shared.port)")! }
    var token: String { Settings.daemonToken }

    /// Where bundled resources live: the app's Resources, or REFLEX_DEV_ROOT.
    static var resources: URL {
        if let dev = ProcessInfo.processInfo.environment["REFLEX_DEV_ROOT"] {
            return URL(fileURLWithPath: dev)
        }
        return Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
    }

    static var binary: URL {
        let r = resources
        let bundled = r.appendingPathComponent("reflexd")
        return FileManager.default.isExecutableFile(atPath: bundled.path)
            ? bundled : r.appendingPathComponent("build/reflexd")
    }

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Reflex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reflexd.log")
    }

    /// GUI apps start with a minimal PATH; agents, herdr and jev-fabric live in
    /// the user's login-shell PATH.
    private static func readLoginPath() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let found = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin",
                     NSHomeDirectory() + "/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return ([found] + extra).filter { !$0.isEmpty }.joined(separator: ":")
    }

    /// The environment for processes Reflex runs for the user (terminal attach):
    /// the login PATH and the configured Herdr session.
    func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        if !Settings.shared.herdrSession.isEmpty { env["HERDR_SESSION"] = Settings.shared.herdrSession }
        return env
    }

    /// Where reflexd listens. Off: this Mac only. Tailscale in userspace
    /// mode delivers tailnet traffic to localhost, so localhost still; with a
    /// Tailscale interface, the network (the phone comes in on it). Without
    /// Tailscale: the network only when you allowed this Wi-Fi.
    static func bind(remote: Bool, lan: Bool, tailnet: Tailnet?) -> String {
        guard remote else { return "127.0.0.1" }
        if let t = tailnet { return t.userspace ? "127.0.0.1" : "0.0.0.0" }
        return lan ? "0.0.0.0" : "127.0.0.1"
    }

    private func environment() -> [String: String] {
        let s = Settings.shared
        let r = Daemon.resources
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        env["REFLEX_TOKEN"] = token
        env["REFLEX_EXIT_WITH_PARENT"] = "1"
        env["REFLEX_PORT"] = String(s.port)
        // The phone remote: with Tailscale in userspace mode, tailnet traffic
        // already arrives on localhost — stay there, reachable from your
        // tailnet only. Otherwise listen on the network.
        env["REFLEX_BIND"] = Daemon.bind(remote: s.remote, lan: s.remoteLAN, tailnet: s.remote ? Tailnet.detect() : nil)
        env["REFLEX_HARNESS"] = s.harness
        // How sure Jev must be to act alone: Reflex's own calibration, not a
        // dial — below it, the bar shows its best guess for you to confirm.
        env["REFLEX_THRESHOLD"] = "6000"
        env["REFLEX_UNDO_MS"] = "0"
        env["REFLEX_FOLDERS_FILE"] = Settings.foldersFile.path
        env["REFLEX_ROOTS"] = s.roots
        env["REFLEX_DATA"] = Settings.supportDir.path
        env["REFLEX_USAGE"] = Settings.supportDir.appendingPathComponent("usage.tsv").path
        env["REFLEX_WEB"] = r.appendingPathComponent("web").path
        env["REFLEX_SCAN"] = r.appendingPathComponent("scripts/reflex-scan.sh").path
        env["REFLEX_FORK"] = r.appendingPathComponent("scripts/reflex-fork.sh").path
        if !s.herdrSession.isEmpty { env["HERDR_SESSION"] = s.herdrSession }
        env["JEV_PROVIDER"] = s.jevProvider
        if !s.jevCredentialCommand.isEmpty {
            env["JEV_CREDENTIAL_COMMAND"] = s.jevCredentialCommand
        } else if let key = Settings.jevKey {
            env[Settings.jevKeyVariable(s.jevProvider)] = key
        }
        return env
    }

    private static var pidURL: URL { Settings.supportDir.appendingPathComponent("reflexd.pid") }

    /// A reflexd left behind by an earlier app instance (crash, kill -9) would
    /// hold the port; stop it if it is still ours.
    private func clearStale() {
        guard let text = try? String(contentsOf: Daemon.pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf).hasSuffix("/reflexd") {
            kill(pid, SIGTERM)
            usleep(300_000)
        }
        try? FileManager.default.removeItem(at: Daemon.pidURL)
    }

    func start() {
        guard process == nil else { return }
        stopping = false
        clearStale()
        let p = Process()
        p.executableURL = Daemon.binary
        p.environment = environment()
        p.currentDirectoryURL = Settings.supportDir
        let log = Daemon.logURL
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.exited(proc.terminationStatus) }
        }
        do {
            try p.run()
            try? String(p.processIdentifier).write(to: Daemon.pidURL, atomically: true, encoding: .utf8)
            process = p
            running = true
            lastError = nil
        } catch {
            lastError = "could not start reflexd: \(error.localizedDescription)"
        }
    }

    private func exited(_ status: Int32) {
        process = nil
        running = false
        guard !stopping else { return }
        lastError = "reflexd exited (\(status)); see \(Daemon.logURL.path)"
        restarts += 1
        let delay = min(Double(restarts) * 1.5, 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
        running = false
    }

    func restart() {
        stop()
        restarts = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.start() }
    }
}

/// A request to reflexd that should be instant (it only queues the work) but
/// was not: one line in ~/Library/Logs/Reflex/app.log, so a send that sat on
/// "Sending" says where it waited.
@MainActor
enum Diag {
    static func slow(_ what: String, since started: Date, over limit: TimeInterval = 2) {
        let took = Date().timeIntervalSince(started)
        guard took >= limit else { return }
        let url = Daemon.logURL.deletingLastPathComponent().appendingPathComponent("app.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) reflexd took \(String(format: "%.1f", took)) s to accept a \(what)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    }
}
