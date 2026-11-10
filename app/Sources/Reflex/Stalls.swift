import Foundation

/// Reflex's own lines (NSLog: windows attaching, moves, stalls) in
/// ~/Library/Logs/Reflex/reflex.log, when nothing else reads them (launched
/// from Finder its stderr is /dev/null); the old one kept as reflex.1.log
/// past 10 MB.
enum EventLog {
    static func start() {
        var err = stat(), null = stat()
        guard fstat(2, &err) == 0, stat("/dev/null", &null) == 0, err.st_rdev == null.st_rdev, (err.st_mode & S_IFMT) == S_IFCHR else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: StallWatch.folder, withIntermediateDirectories: true)
        let url = StallWatch.folder.appendingPathComponent("reflex.log")
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 10_000_000 {
            let old = StallWatch.folder.appendingPathComponent("reflex.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        guard freopen(url.path, "a", stderr) != nil else { return }
        setvbuf(stderr, nil, _IOLBF, 0)
    }
}

/// The main thread stalling: typing, terminals and the rail all wait on it.
/// A watcher off it asks every 50 ms; a stall past 250 ms is logged, and one
/// still stuck at 300 ms is sampled while it lasts (macOS's `sample`, at most
/// once a minute) to ~/Library/Logs/Reflex/stall-<time>.txt: what Reflex was
/// doing, for a lag that's hard to catch otherwise.
final class StallWatch: @unchecked Sendable {
    static let shared = StallWatch()

    private let lock = NSLock()
    private var answered = true
    private var askedAt = DispatchTime.now()
    private var sampling = false
    private var sampledAt = Date.distantPast
    private var started = false

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Reflex", isDirectory: true)
    }

    func start() {
        guard lock.withLock({ let was = started; started = true; return !was }) else { return }
        Thread.detachNewThread { [self] in
            Thread.current.name = "reflex.stallwatch"
            while true {
                let (ok, since) = lock.withLock { (answered, askedAt) }
                if ok {
                    let at = DispatchTime.now()
                    lock.withLock { answered = false; askedAt = at }
                    DispatchQueue.main.async { [self] in
                        lock.withLock { answered = true }
                        let waited = Double(DispatchTime.now().uptimeNanoseconds - at.uptimeNanoseconds) / 1e6
                        if waited > 250 { NSLog("Reflex: main thread stalled %.0f ms", waited) }
                    }
                } else if Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6 > 300 {
                    sample()
                }
                usleep(50_000)
            }
        }
    }

    /// `sample` on this process for 2 s, while the stall lasts.
    private func sample() {
        let go = lock.withLock { () -> Bool in
            guard !sampling, Date().timeIntervalSince(sampledAt) > 60 else { return false }
            sampling = true
            sampledAt = Date()
            return true
        }
        guard go else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        // The newest 20 only.
        if let old = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("stall-") }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(19) {
            old.forEach { try? fm.removeItem(at: $0) }
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = Self.folder.appendingPathComponent("stall-\(stamp).txt")
        NSLog("Reflex: main thread stuck past 300 ms: sampling to %@", file.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-mayDie", "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [self] _ in lock.withLock { sampling = false } }
        if (try? p.run()) == nil { lock.withLock { sampling = false } }
    }
}

/// reflexd stuck: not answering (the app then shows its empty first state,
/// "herdr-core and herdr unreachable"), or saying herdr-core is unreachable
/// while it answers the app. It used to take a force quit; now, at most every
/// two minutes, the stuck daemon is sampled (~/Library/Logs/Reflex/
/// reflexd-stuck-<time>.txt, with its open files) and restarted.
@MainActor
final class DaemonWatch {
    static let shared = DaemonWatch()
    private var timer: Timer?
    private var herdrOffSince: Date?
    private var recoveredAt = Date.distantPast
    private var recovering = false
    private let born = Date()

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { DaemonWatch.shared.check() }
        }
    }

    private func check() {
        // (A daemon just started has a moment to come up.)
        guard Daemon.shared.running, !recovering, Date().timeIntervalSince(born) > 30 else { return }
        let silent = Date().timeIntervalSince(Store.shared.lastOK)
        if silent > 20 {
            // (Asked again first: after sleep, or a throttled poll, it answers.)
            recovering = true
            Task {
                let ok = await Client.local.answers(within: 8)
                recovering = false
                if !ok { recover("reflexd hasn't answered for \(Int(Date().timeIntervalSince(Store.shared.lastOK))) s") }
            }
            return
        }
        guard Settings.shared.usesCore, !Store.shared.state.herdr else { herdrOffSince = nil; return }
        guard let since = herdrOffSince else { herdrOffSince = Date(); return }
        guard Date().timeIntervalSince(since) > 30 else { return }
        Task {
            // Only when herdr-core answers us: then it's reflexd that's wrong.
            if (try? await HerdrCore.call("terminal.list", [:], timeout: 3)) != nil {
                recover("reflexd has said herdr-core is unreachable for \(Int(Date().timeIntervalSince(since))) s, but it answers")
            }
        }
    }

    private func recover(_ why: String) {
        guard Date().timeIntervalSince(recoveredAt) > 120, let pid = Daemon.shared.pid else { return }
        recoveredAt = Date()
        recovering = true
        herdrOffSince = nil
        let folder = StallWatch.folder
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("reflexd-stuck-\(stamp).txt")
        Task {
            let files = await Blocking.run { () -> Int in
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let n = Self.run("/usr/sbin/lsof", ["-p", String(pid)]).split(separator: "\n").count
                _ = Self.run("/usr/bin/sample", [String(pid), "3", "-mayDie", "-file", file.path])
                return n
            }
            await MainActor.run {
                Diag.log("\(why): restarted it (pid \(pid), \(files) open files; sampled to \(file.lastPathComponent))")
                NSLog("Reflex: %@: restarting reflexd", why)
                Daemon.shared.restart()
                DaemonWatch.shared.recovering = false
            }
        }
    }

    nonisolated private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
