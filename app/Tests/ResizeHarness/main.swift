// A window's view of a herdr-core terminal across resizes: see scripts/test-resize.sh.
// The stream is drawn into SwiftTerm as AgentPopout draws it, the window is
// resized as a window is, and after each settle the view must show what the
// core's own screen shows.
import Foundation
import SwiftTerm

final class Sink: TerminalDelegate {
    static let shared = Sink()
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

let name = CommandLine.arguments.dropFirst().first ?? "tui"
let link = CoreLink.shared
var term = Terminal(delegate: Sink.shared, options: TerminalOptions(cols: 80, rows: 24, scrollback: 2000))
var failures = 0

func screen(_ t: Terminal) -> [String] {
    var out: [String] = []
    // Only the columns a view draws: a narrowed line keeps its wider cells.
    for r in 0..<t.rows { out.append(t.getLine(row: r)?.translateToString(trimRight: true, startCol: 0, endCol: t.cols) ?? "") }
    return out.map(trimmed)
}

/// Without trailing blanks: spaces, and the NULs of cells never written.
func trimmed(_ s: String) -> String {
    var u = Array(s.unicodeScalars)
    while let l = u.last, l == "\u{0}" || CharacterSet.whitespaces.contains(l) { u.removeLast() }
    return String(String.UnicodeScalarView(u))
}

func coreScreen() async throws -> [String] {
    let r = try await link.call("terminal.read", ["terminal": name])
    var rows = (r["text"] as? String ?? "").components(separatedBy: "\n").map(trimmed)
    while rows.count < term.rows { rows.append("") }
    return Array(rows.prefix(term.rows))
}

func compare(_ what: String) async throws {
    let mine = screen(term), core = try await coreScreen()
    let bad = (0..<min(mine.count, core.count)).filter { mine[$0] != core[$0] }
    if bad.isEmpty { print("ok   \(what): the view matches the core (\(term.cols)×\(term.rows))"); return }
    failures += 1
    print("FAIL \(what): \(bad.count) of \(term.rows) rows differ (\(term.cols)×\(term.rows))")
    for r in bad.prefix(6) {
        print("  row \(r) view: \(mine[r].prefix(110))")
        print("  row \(r) core: \(core[r].prefix(110))")
    }
}

func pause(_ s: Double) async throws { try await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

let sem = DispatchSemaphore(value: 0)
Task { @MainActor in
    do {
        // As AgentPopout.attachCore: a fresh screen, then the core's paint.
        term.feed(text: CorePaint.blank)
        let s = try await link.attach(name, cols: 80, rows: 24, history: 2000)
        s.start(data: { d in term.feed(byteArray: [UInt8](d)) }, closed: { why in print("closed:", why) })
        try await pause(4)
        try await compare("first paint")
        // A window dragged wider: a resize per frame, the view's first.
        for (c, r) in [(86, 25), (93, 26), (100, 28), (107, 29)] {
            term.resize(cols: c, rows: r)
            s.resize(cols: c, rows: r)
            try await pause(0.03)
        }
        try await pause(1.5)
        try await compare("wider")
        for (c, r) in [(96, 27), (84, 24), (70, 20)] {
            term.resize(cols: c, rows: r)
            s.resize(cols: c, rows: r)
            try await pause(0.03)
        }
        try await pause(1.5)
        try await compare("narrower")
        term.resize(cols: 107, rows: 29)
        s.resize(cols: 107, rows: 29)
        try await pause(1.5)
        try await compare("wide again")

        // A reconnect: the view's screen holds an older frame (here, junk on
        // every row of the program's alternate screen), and the core paints
        // again. What the new paint leaves blank must not keep the old rows.
        term.feed(text: (1...29).map { "\u{1b}[\($0);1Hstale row \($0) from an older frame" }.joined())
        s.close()
        let again = try await link.attach(name, cols: 107, rows: 29, history: 2000)
        var firstAgain = true
        again.start(data: { d in
            if firstAgain { firstAgain = false; term.feed(text: CorePaint.blank) }
            term.feed(byteArray: [UInt8](d))
        }, closed: { _ in })
        try await pause(1.5)
        try await compare("reattached over an older frame")

        // Another window views it at its own size and takes the size: this
        // view follows (watches at that size, its grid pinned to it) while
        // the program draws for that window, then takes the size back.
        // TerminalSession.gotFacts and swap, step for step.
        var stream = again
        var sizing = CoreSize()
        var following = false
        let own = (cols: 107, rows: 29)
        var steps: [CoreSize.Step] = []
        var line = Data()
        let facts = try await link.subscribe(name)
        facts.start(data: { d in
            line.append(d)
            while let nl = line.firstIndex(of: 0x0a) {
                let l = line[line.startIndex..<nl]
                line.removeSubrange(line.startIndex...nl)
                guard let v = try? JSONSerialization.jsonObject(with: l) as? [String: Any],
                      let p = v["params"] as? [String: Any], p["type"] as? String == "size",
                      let sz = p["data"] as? [String: Any], let c = sz["cols"] as? Int, let r = sz["rows"] as? Int else { continue }
                let step = sizing.sized(cols: c, rows: r, own: own, following: following)
                if step != .stay { steps.append(step) }
            }
        }, closed: { _ in })
        func swap(follow size: (cols: Int, rows: Int)? = nil) async throws {
            let cols = size?.cols ?? own.cols, rows = size?.rows ?? own.rows
            let n = try await link.attach(name, cols: cols, rows: rows, history: 2000, observe: size != nil)
            stream.close()
            stream = n
            sizing.painted()
            following = size != nil
            var first = true
            n.start(data: { d in
                if first { first = false; term.resize(cols: cols, rows: rows); term.feed(text: CorePaint.blank) }
                term.feed(byteArray: [UInt8](d))
            }, closed: { _ in })
            try await pause(1.5)
        }
        // The last step since `from`, acted on as the session would.
        func act(from: Int) async throws -> CoreSize.Step? {
            guard steps.count > from, let step = steps.last else { return nil }
            switch step {
            case .follow(let c, let r): try await swap(follow: (c, r))
            case .own, .repaint: try await swap()
            case .stay: break
            }
            return step
        }

        for (c, r) in [(107, 17), (92, 38)] {
            let other = try await link.attach(name, cols: c, rows: r)
            other.start(data: { _ in }, closed: { _ in })
            other.focus(true)
            try await pause(0.8)
            let followed = try await act(from: 0)
            check(followed == .follow(cols: c, rows: r), "another window's \(c)×\(r): this view follows it")
            steps = []
            // The program draws while that window has it: typed there.
            for ch in "typed in the other window " {
                other.write(Data(String(ch).utf8))
                try await pause(0.02)
            }
            try await pause(1)
            try await compare("following \(c)×\(r) while that window types")
            // Used here again: take the size back.
            try await swap()
            try await compare("taken back")
            check(!following, "taking it back ends following")
            steps = []
            other.close()
            try await pause(0.8)
            check(steps.isEmpty, "that window leaving changes nothing here")
        }

        // Following when the other window leaves: nobody sizes it (the core's
        // headless size), so this one takes it back rather than follow.
        let other = try await link.attach(name, cols: 90, rows: 25)
        other.start(data: { _ in }, closed: { _ in })
        try await pause(0.8)
        _ = try await act(from: 0)
        check(following, "following 90×25")
        steps = []
        other.close()
        try await pause(0.8)
        let back = try await act(from: 0)
        check(back == .own, "the other window left: this one takes the size back")
        try await compare("after the other window left")
        check(!sizing.stale, "a paint leaves the view current")
        facts.close()
        stream.close()
    } catch { print("FAIL", error); exit(1) }
    sem.signal()
}
while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date() + 0.05) }
print(failures == 0 ? "Resize: all checks passed" : "Resize: \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
