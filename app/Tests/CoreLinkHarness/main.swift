// CoreLink (app/Sources/Reflex/CoreLink.swift) against a real core: see scripts/test-corelink.sh.
import Foundation
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { exit(1) } }
let link = CoreLink.shared
var got = Data()
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let list = try await link.call("terminal.list", [:])
        check((list["terminals"] as? [Any])?.count == 1, "framed call: terminal.list")
        let s = try await link.attach("echo", cols: 70, rows: 20, history: 100)
        s.start(data: { d in got.append(d) }, closed: { why in print("closed:", why) })
        try await Task.sleep(nanoseconds: 800_000_000)
        check(String(decoding: got, as: UTF8.self).contains("ready"), "first paint has the screen")
        s.write(Data("hello\r".utf8))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        check(String(decoding: got, as: UTF8.self).contains("got:hello"), "keys typed down the stream reach the program")
        s.facts(["fg": "#c0caf5", "bg": "#1a1b26", "cell": [16, 34]])
        s.resize(cols: 91, rows: 27)
        try await Task.sleep(nanoseconds: 800_000_000)
        let t = try await link.call("terminal.get", ["terminal": "echo"])
        check((t["cols"] as? Int) == 91 && (t["rows"] as? Int) == 27, "resize sets the terminal's size")
        // Lots of output: credit keeps it flowing past the first 256 KiB.
        got = Data()
        s.write(Data("big\r".utf8))
        try await Task.sleep(nanoseconds: 2_500_000_000)
        check(got.count > 600_000, "flow control: \(got.count) bytes past the initial credit")
        s.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        let again = try await link.attach("echo", cols: 91, rows: 27, observe: true)
        var seen = Data()
        again.start(data: { d in seen.append(d) }, closed: { _ in })
        try await Task.sleep(nanoseconds: 600_000_000)
        check(!seen.isEmpty, "reattach (observe) paints again")
        again.close()
    } catch { print("FAIL", error); exit(1) }
    sem.signal()
}
while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date() + 0.05) }
print("CoreLink: all checks passed")
