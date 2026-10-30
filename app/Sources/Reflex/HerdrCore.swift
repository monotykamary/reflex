import Darwin
import Foundation

// herdr-core (`hc`): the terminal runtime Reflex's agents live in by
// default. herdr (the TUI) still works alongside it while people move over:
// reflexd lists both, and a pane id says which one an agent is in (herdr's
// hold a ':', the core's are "t7" or "box/t7"; see daemon/Term.bend).
//
// Two ways in, as the core's API docs describe:
// - plain JSON-RPC over its socket, one request per connection (`call`):
//   the socket is worked out here exactly as the core does, and handed to
//   reflexd too;
// - a framed connection through `hc connect` (CoreLink), which carries
//   terminal streams: the windows' live terminals and the phone's screens.
//
// The core draws nothing, never guesses status from the screen and keeps
// its terminals running across its own updates and restarts.

enum HerdrCore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var snapshot: (session: String, env: [String: String]) =
        ("default", ProcessInfo.processInfo.environment)

    /// Takes the session and environment from Settings and the daemon (on
    /// the main actor), for the threads that talk to the core.
    @MainActor static func prime() {
        let s = Settings.shared.coreSession.trimmingCharacters(in: .whitespaces)
        var env = Daemon.shared.childEnvironment()
        env["HC_SESSION"] = s.isEmpty ? "default" : s
        env["HC_TERMINAL_ID"] = nil
        lock.withLock { snapshot = (s.isEmpty ? "default" : s, env) }
        // Another core now: its streams can't come from the old one's line.
        CoreLink.shared.reset()
    }

    /// The core Reflex talks to (HC_SESSION): "default" unless set.
    static var session: String { lock.withLock { snapshot.session } }

    static func isCore(_ pane: String) -> Bool { !pane.isEmpty && !pane.contains(":") }

    /// The environment every `hc` Reflex runs gets: the login PATH, this
    /// session, and nothing that would make it think it runs inside a core
    /// terminal (Reflex launched from one, a dev build).
    static func environment() -> [String: String] { lock.withLock { snapshot.env } }

    /// Its socket, the way the core finds it (paths.rs): HC_SOCKET, else
    /// `socket` in its config, else <runtime dir>/herdr-core/<session>.sock,
    /// else beside its state in ~/.local/state/herdr-core/<session>/.
    static func socketPath(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let s = env["HC_SOCKET"], !s.isEmpty { return s }
        let home = env["HOME"] ?? NSHomeDirectory()
        let config = (env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config") + "/herdr-core/config.toml"
        if let s = configSocket(config) { return s }
        let name = "\(session).sock"
        if let run = env["XDG_RUNTIME_DIR"], !run.isEmpty { return "\(run)/herdr-core/\(name)" }
        let user = "/run/user/\(getuid())"
        if FileManager.default.fileExists(atPath: user) { return "\(user)/herdr-core/\(name)" }
        let state = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/state"
        return "\(state)/herdr-core/\(session)/\(name)"
    }

    /// `socket = "..."` at the top level of the core's config, if set.
    private static func configSocket(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { break }
            guard l.hasPrefix("socket"), let eq = l.firstIndex(of: "=") else { continue }
            let v = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let unquoted = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !unquoted.isEmpty { return (unquoted as NSString).expandingTildeInPath }
        }
        return nil
    }

    /// The installed core: `herdr-core` (or the `hc` link to it) on the
    /// login PATH, or where its installer puts it.
    static func binary(_ env: [String: String] = environment()) -> String? {
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + [NSHomeDirectory() + "/.local/bin"]
        for d in dirs {
            for n in ["herdr-core", "hc"] where FileManager.default.isExecutableFile(atPath: "\(d)/\(n)") {
                return "\(d)/\(n)"
            }
        }
        return nil
    }

    struct Failure: Error, LocalizedError {
        let kind: String
        let message: String
        var errorDescription: String? { message }
    }

    /// One JSON-RPC request on the socket; its result. Blocking: call it off
    /// the main thread (see `request`).
    static func callSync(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 5,
                         socket path: String? = nil) throws -> [String: Any] {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        var line = try JSONSerialization.data(withJSONObject: body)
        line.append(0x0a)
        let reply = try UnixLine.exchange(path ?? socketPath(environment()), line, timeout: timeout)
        guard let v = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw Failure(kind: "protocol", message: "herdr-core sent something that isn't JSON")
        }
        if let e = v["error"] as? [String: Any] {
            let data = e["data"] as? [String: Any]
            throw Failure(kind: data?["kind"] as? String ?? "error",
                          message: [e["message"] as? String, data?["hint"] as? String].compactMap { $0 }.joined(separator: " — "))
        }
        return v["result"] as? [String: Any] ?? [:]
    }

    static func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 5) async throws -> [String: Any] {
        let path = socketPath(environment())
        nonisolated(unsafe) let p = params
        return try await Task.detached { try callSync(method, p, timeout: timeout, socket: path) }.value
    }

    /// Runs the core's CLI (`hc <args> --json` and the like): its exit code
    /// and output. Blocking.
    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 30) -> (status: Int32, out: String, err: String) {
        guard let bin = binary() else { return (127, "", "herdr-core isn't installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = environment()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (126, "", error.localizedDescription) }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

/// One newline-terminated request and its one-line reply over a Unix socket.
enum UnixLine {
    static func exchange(_ path: String, _ line: Data, timeout: TimeInterval, max: Int = 16 << 20) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        try line.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE) }
                sent += n
            }
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while reply.last != 0x0a {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else {
                if reply.isEmpty { throw POSIXError(n == 0 ? .ECONNRESET : (POSIXErrorCode(rawValue: errno) ?? .ETIMEDOUT)) }
                break
            }
            reply.append(contentsOf: chunk[0..<n])
            guard reply.count <= max else { throw POSIXError(.EMSGSIZE) }
        }
        return reply
    }
}

/// Keeps the core running, as HerdrServer does herdr's: asking for its
/// status starts it when it isn't (it detaches by itself), and its
/// terminals survive whatever happens to Reflex. Installed and not
/// answering is enough to start it: reflexd may be getting by on herdr
/// meanwhile. Settings → Setup turns this off.
@MainActor
enum CoreServer {
    private static var lastTry = Date.distantPast
    private static let interval: TimeInterval = 20
    private static var checked = Date.distantPast
    private static var found = false

    /// herdr-core is installed (looked for at most every 20 s).
    static var installed: Bool {
        if Date().timeIntervalSince(checked) > interval {
            checked = Date()
            found = HerdrCore.binary() != nil
        }
        return found
    }

    static func ensure() {
        guard Settings.shared.startCore, Date().timeIntervalSince(lastTry) > interval else { return }
        lastTry = Date()
        DispatchQueue.global(qos: .utility).async {
            guard HerdrCore.binary() != nil, (try? HerdrCore.callSync("server.status", timeout: 2)) == nil else { return }
            let r = HerdrCore.run(["server", "status", "--json"], timeout: 20)
            NSLog("Reflex: herdr-core wasn't answering; `hc server status` %@", r.status == 0 ? "started it" : "failed: \(r.err)")
        }
    }
}

/// The machines herdr-core has added (`machine.list`): their agents arrive
/// through the core itself, addressed "box/t7", with no tunnel of Reflex's.
/// Kept fresh by Settings → Machines and by RemoteIndex's rounds.
enum CoreMachines {
    struct Machine: Hashable {
        let name: String
        let target: String
        /// "connected", "connecting", "needs_login", "needs_update", ...
        let state: String
        let why: String
        let version: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [Machine] = []
    nonisolated(unsafe) private static var at = Date.distantPast

    /// The last list read, without waiting.
    static var known: [Machine] { lock.withLock { cached } }

    /// The list, read again when it is more than `fresh` seconds old.
    static func list(fresh: TimeInterval = 10) async -> [Machine] {
        let old = lock.withLock { Date().timeIntervalSince(at) > fresh }
        guard old else { return known }
        guard let r = try? await HerdrCore.call("machine.list", [:], timeout: 3) else { return known }
        let ms = (r["machines"] as? [[String: Any]] ?? []).compactMap { m -> Machine? in
            guard let name = m["name"] as? String, (m["temporary"] as? Bool) != true else { return nil }
            return Machine(name: name, target: m["target"] as? String ?? m["host"] as? String ?? "",
                           state: m["state"] as? String ?? "", why: m["why"] as? String ?? "",
                           version: m["version"] as? String ?? "")
        }
        lock.withLock {
            cached = ms
            at = Date()
        }
        return ms
    }

    /// One the core reaches now.
    static func has(_ name: String) async -> Bool { await list().contains { $0.name == name && $0.state == "connected" } }

    /// Run `line` in that machine's shell through the core, `input` on its
    /// stdin: what it printed, if it exited 0.
    static func exec(_ name: String, _ line: String, input: String, timeout: TimeInterval) -> String? {
        let params: [String: Any] = ["on": name, "line": line, "input": Data(input.utf8).base64EncodedString(),
                                     "timeout": min(600, timeout)]
        guard let r = try? HerdrCore.callSync("machine.exec", params, timeout: timeout + 10),
              (r["code"] as? Int) == 0, let out = (r["stdout"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}
