import Darwin
import Foundation

// herdr's server, started when it isn't running (after a restart, say), the
// way herdr's own client starts it: `herdr server`, headless and detached in a
// session of its own (setsid), for the configured session. A server that
// doesn't lead its own session works here but not from another Mac: herdr's
// saved machines (`herdr machine add`) refuse it until it's restarted. Your
// agents and their terminals live there; Reflex only makes sure it's up.
// Settings → Setup turns this off.

@MainActor
enum HerdrServer {
    private static var lastTry = Date.distantPast
    /// Between tries: a server takes a moment to come up, and one that won't
    /// start shouldn't be restarted over and over.
    private static let interval: TimeInterval = 20

    /// reflexd answered, and says herdr didn't: start it.
    static func ensure(reachable: Bool) {
        guard !reachable, Settings.shared.startHerdr, Date().timeIntervalSince(lastTry) > interval else { return }
        let env = Daemon.shared.childEnvironment()
        let path = env["PATH"] ?? ""
        guard let herdr = path.split(separator: ":").map({ "\($0)/herdr" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        lastTry = Date()
        let session = Settings.shared.herdrSession
        let args = [herdr] + (session.isEmpty ? [] : ["--session", session]) + ["server"]
        do {
            let pid = try spawnDetached(args, env: env)
            // The server outlives Reflex; while Reflex runs, reap it if it exits.
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
            NSLog("Reflex: herdr wasn't running; started herdr server%@",
                  session.isEmpty ? "" : " (session \(session))")
        } catch {
            NSLog("Reflex: couldn't start herdr server: %@", error.localizedDescription)
        }
    }

    /// `argv` as the leader of a new session, stdio on /dev/null, no file
    /// descriptors of Reflex's and default signal handling: what herdr's own
    /// client does, which `Process` can't (it has no setsid).
    private static func spawnDetached(_ argv: [String], env: [String: String]) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&files, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&files, 2, "/dev/null", O_WRONLY, 0)

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &files, &attr, cArgs, cEnv)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EINVAL) }
        return pid
    }
}
