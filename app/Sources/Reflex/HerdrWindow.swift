import AppKit

// "Show in herdr": focus the pane in herdr, then bring the terminal that shows
// herdr to the front. If no herdr client is attached anywhere, open one (in
// Ghostty when installed, else Terminal) — it attaches already on that pane.
// A pane on another Mac opens herdr's own remote attach to that machine.
// A herdr-core terminal has no app of its own to show it: Reflex's terminal
// window does.

@MainActor
enum HerdrWindow {
    static func reveal(pane: String) {
        // herdr-core draws nothing: its terminal opens in Reflex's own window.
        if HerdrCore.isCore(pane) {
            AppDelegate.current?.showPane(pane)
            return
        }
        Task {
            await Client.local.focus(pane)
            if let m = MachinesModel.shared.row(Machines.machine(of: pane)) {
                // Its herdr already open here (`herdr --remote <target>`): that window.
                if let app = hostOfClient(remote: m.target) {
                    app.activate()
                    return
                }
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

    /// The app (Ghostty, Terminal, …) whose process tree runs a herdr TUI
    /// client: this Mac's, or with `remote`, one attached to that machine.
    private static func hostOfClient(remote: String? = nil) -> NSRunningApplication? {
        let rows = processes()
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = ProcessInfo.processInfo.processIdentifier
        for r in rows where isClient(r.command, remote: remote) {
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
    /// or one-shot API commands, and not Reflex's own terminal attaches. With
    /// `remote`: `herdr --remote <remote>` only; without, not those.
    private static func isClient(_ command: String, remote: String? = nil) -> Bool {
        let parts = command.split(separator: " ").map(String.init)
        guard let exe = parts.first, (exe as NSString).lastPathComponent == "herdr" else { return false }
        let to = parts.firstIndex(of: "--remote").flatMap { parts.indices.contains($0 + 1) ? parts[$0 + 1] : nil }
        guard to == remote else { return false }
        // The words left once options and their values are gone: `--session x`
        // names a session, not a subcommand.
        var args: [String] = []
        var skip = false
        for p in parts.dropFirst() {
            if skip { skip = false; continue }
            if ["--session", "--remote", "--remote-keybindings", "--machine"].contains(p) { skip = true; continue }
            if !p.hasPrefix("-") { args.append(p) }
        }
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
