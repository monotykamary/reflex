// PhoneLink (app/Sources/Reflex/PhoneLink.swift) against a real core, asked
// as reflexd asks it: see scripts/test-corelink.sh.
import AppKit
import Foundation

func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { exit(1) } }

/// One JSON line to the app's socket, as daemon/Link.bend sends it.
func ask(_ method: String, _ params: [String: Any]) -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(AppLink.path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { b in b.copyBytes(from: bytes); b[bytes.count] = 0 }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    var line = try! JSONSerialization.data(withJSONObject: ["method": method, "params": params])
    line.append(0x0a)
    line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    var reply = Data()
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; reply.append(contentsOf: buf[0..<n]) }
    close(fd)
    return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] ?? [:]
}

_ = NSApplication.shared
// A test, not an app: no Dock icon, never takes focus.
NSApp.setActivationPolicy(.prohibited)
AppLink.shared.start()
// REFLEX_LINK_HOLD=<seconds>: just serve the link (for a reflexd to ask).
if let hold = ProcessInfo.processInfo.environment["REFLEX_LINK_HOLD"].flatMap(Double.init) {
    print("serving \(AppLink.path)")
    fflush(stdout)  // a pipe buffers it otherwise, until exit
    // The main run loop has no sources of its own here: turn it until then.
    let end = Date() + hold
    while Date() < end { RunLoop.main.run(until: Date() + 0.05) }
    AppLink.shared.stop()
    exit(0)
}
DispatchQueue.global().async {
    sleep(1)
    let s = ask("screen", ["terminal": "color"])
    let text = s["text"] as? String ?? ""
    check(s["ok"] as? Bool == true && text.contains("red here"), "screen: the program's text")
    check(text.contains("\u{1b}[0;31m") || text.contains(";31m"), "screen: with its colors (SGR)")
    check(!text.split(separator: "\n").contains { $0.hasSuffix(" ") }, "screen: no padding past the last character")
    let c = ask("control", ["terminal": "color", "cols": 63, "rows": 19, "take": false])
    check(c["ok"] as? Bool == true && c["held"] as? Bool == false, "control: the phone sizes it (no window here)")
    let t = ask("type", ["terminal": "color", "text": "typed\r"])
    check(t["ok"] as? Bool == true, "type: accepted")
    sleep(1)
    let after = ask("screen", ["terminal": "color"])["text"] as? String ?? ""
    check(after.contains("got:typed"), "type: reached the program")
    let size = ask("screen", ["terminal": "nope"])
    check(size["ok"] as? Bool == false, "screen: an unknown terminal fails")
    DispatchQueue.main.async {
        Task {
            let r = try? await HerdrCore.call("terminal.get", ["terminal": "color"])
            check(r?["cols"] as? Int == 63 && r?["rows"] as? Int == 19, "control: the terminal took the phone's size")
            AppLink.shared.stop()
            print("PhoneLink: all checks passed")
            exit(0)
        }
    }
}
RunLoop.main.run(until: Date() + 30)
print("FAIL timed out"); exit(1)
