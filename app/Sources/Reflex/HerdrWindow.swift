import AppKit

// "Show in herdr": focus the pane in herdr, then bring the terminal that shows
// herdr to the front. If no herdr client is attached anywhere, open one (in
// Ghostty when installed, else Terminal) — it attaches already on that pane.
// A pane on another Mac opens herdr's own remote attach to that machine.

@MainActor
enum HerdrWindow {
    static func reveal(pane: String) {
        Task {
            await Client.local.focus(pane)
            if let m = MachinesModel.shared.row(Machines.machine(of: pane)) {
                let session = m.session.isEmpty || m.session == "default" ? "" : " --session \(quoted(m.session))"
                openClient("herdr --remote \(quoted(m.target))" + session)
            } else if let app = hostOfClient() {
                app.activate()
            } else {
                let session = Settings.shared.herdrSession
                openClient("herdr" + (session.isEmpty ? "" : " --session \(session)"))
            }
        }
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The app (Ghostty, Terminal, …) whose process tree runs a herdr TUI client.
    private static func hostOfClient() -> NSRunningApplication? {
        let rows = processes()
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = ProcessInfo.processInfo.processIdentifier
        for r in rows where isClient(r.command) {
            var pid = r.ppid
            var hops = 0
            while pid > 1 && hops < 32 {
                if pid == mine { break }
                if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil {
                    return app
                }
                guard let up = byPid[pid] else { break }
                pid = up.ppid
                hops += 1
            }
        }
        return nil
    }

    /// `herdr`, `herdr --session x`, `herdr session attach x` — not the server
    /// or one-shot API commands, and not Reflex's own terminal attaches.
    private static func isClient(_ command: String) -> Bool {
        let parts = command.split(separator: " ").map(String.init)
        guard let exe = parts.first, (exe as NSString).lastPathComponent == "herdr" else { return false }
        let args = Array(parts.dropFirst()).filter { !$0.hasPrefix("-") }
        guard let verb = args.first else { return true }
        if verb == "session" { return args.dropFirst().first == "attach" }
        return false
    }

    private struct Row { var pid: pid_t; var ppid: pid_t; var command: String }

    private static func processes() -> [Row] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { return nil }
            return Row(pid: pid, ppid: ppid, command: String(f[2]))
        }
    }

    private static func openClient(_ herdr: String) {
        let ghostty = ["/Applications/Ghostty.app", NSHomeDirectory() + "/Applications/Ghostty.app"]
            .first { FileManager.default.fileExists(atPath: $0) }
        if let ghostty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", ghostty, "--args", "-e", "/bin/zsh", "-lic", herdr]
            try? p.run()
            return
        }
        let script = Settings.supportDir.appendingPathComponent("herdr.command")
        try? "#!/bin/zsh -li\nexec \(herdr)\n".write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
