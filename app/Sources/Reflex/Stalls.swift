import Foundation

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
