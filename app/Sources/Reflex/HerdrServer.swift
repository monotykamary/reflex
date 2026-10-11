import Foundation

// herdr's server, started when it isn't running (after a restart, say), the
// way herdr's own client starts it: `herdr server`, headless and detached, for
// the configured session. Your agents and their terminals live there; Reflex
// only makes sure it's up. Settings → Setup turns this off.

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
        guard path.split(separator: ":").contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/herdr") }) else { return }
        lastTry = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup and a background job: the server outlives this shell and Reflex.
        let session = Settings.shared.herdrSession
        p.arguments = ["-c", "nohup herdr \(session.isEmpty ? "" : "--session \"$1\" ")server >/dev/null 2>&1 &", "herdr-start", session]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            NSLog("Reflex: herdr wasn't running; started herdr server%@",
                  Settings.shared.herdrSession.isEmpty ? "" : " (session \(Settings.shared.herdrSession))")
        } catch {
            NSLog("Reflex: couldn't start herdr server: %@", error.localizedDescription)
        }
    }
}
