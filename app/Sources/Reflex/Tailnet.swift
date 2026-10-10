import Foundation

// This Mac on your tailnet, asked of tailscaled itself rather than guessed
// from network interfaces — a headless tailscaled in userspace mode
// (`--tun=userspace-networking`) has no 100.x interface at all:
//
//   1. tailscaled's local API socket (open-source / Homebrew / headless)
//   2. the tailscale CLI (the Mac app bundles one; Homebrew, go install)
//   3. an interface in 100.64.0.0/10 (any TUN setup without either)
//
// In userspace mode tailscaled hands tailnet connections to localhost, so
// reflexd can stay on 127.0.0.1 and still be reachable — from your tailnet
// only, never your Wi-Fi.

struct Tailnet: Equatable {
    /// MagicDNS name, without the trailing dot ("mac.tail1234.ts.net").
    var dns: String?
    var ip: String?
    /// No TUN interface: tailnet traffic arrives on localhost.
    var userspace: Bool

    /// The address the phone link uses: the stable name when there is one.
    var host: String? { dns ?? ip }

    static let sockets = ["/var/run/tailscaled.socket", "/var/run/tailscale/tailscaled.sock"]
    static var clis: [String] {
        let home = NSHomeDirectory()
        return ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale",
                "/usr/local/bin/tailscale", home + "/go/bin/tailscale", home + "/.local/bin/tailscale"]
    }

    /// Ask tailscaled; nil when Tailscale is not running here.
    static func detect() -> Tailnet? {
        for sock in sockets where FileManager.default.fileExists(atPath: sock) {
            if let t = parse(run("/usr/bin/curl", ["-s", "-m", "2", "--unix-socket", sock, "-H", "Host: local-tailscaled.sock",
                                                   "http://local-tailscaled.sock/localapi/v0/status"])) { return t }
        }
        for cli in clis where FileManager.default.isExecutableFile(atPath: cli) {
            if let t = parse(run(cli, ["status", "--json"])) { return t }
        }
        if let ip = Remote.addresses.first(where: Remote.isTailscale) {
            return Tailnet(dns: nil, ip: ip, userspace: false)
        }
        return nil
    }

    static func parse(_ data: Data?) -> Tailnet? {
        guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (j["BackendState"] as? String) == "Running", let me = j["Self"] as? [String: Any] else { return nil }
        let ips = me["TailscaleIPs"] as? [String] ?? []
        var dns = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        if dns?.isEmpty == true { dns = nil }
        let tun = j["TUN"] as? Bool ?? true
        return Tailnet(dns: dns, ip: ips.first { !$0.contains(":") } ?? ips.first, userspace: !tun)
    }

    private static func run(_ exe: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}

/// The tailnet, looked up off the main thread and kept for the UI.
@MainActor
final class TailnetState: ObservableObject {
    static let shared = TailnetState()
    @Published private(set) var current: Tailnet?
    @Published private(set) var checked = false

    func refresh() {
        Task.detached(priority: .utility) {
            let t = Tailnet.detect()
            await MainActor.run {
                if self.current != t { self.current = t }
                self.checked = true
            }
        }
    }
}
