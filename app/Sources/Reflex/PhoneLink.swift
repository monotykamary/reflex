import AppKit
import Darwin
import Foundation
import SwiftTerm

// The phone's terminal onto a herdr-core agent. herdr read a pane's screen
// with its colors and let a client size it and scroll it (`terminal session
// control`); the core instead streams a terminal's bytes to whoever attaches.
// So the app attaches for the phone, keeps the screen in a terminal emulator
// that draws nothing (SwiftTerm, as the windows use), and reflexd asks it
// for that screen — for these agents, /api/pane, /api/text and /api/term
// come here (see daemon/Link.bend) over <support>/link.sock: one JSON line
// asked, one answered, per connection.
//
//   screen  {terminal}                    → {text}: the screen as ANSI
//   type    {terminal, text}              → keys as typed, no Enter
//   control {terminal, cols, rows, take, scroll, n}
//                                         → {ok, held}: the phone's size; held
//           while a window on this Mac has it, until the phone takes it
//
// A viewer watches (never types or resizes) until the phone types or sizes
// it, and is let go a little after the phone stops asking.

@MainActor
final class PhoneScreens {
    static let shared = PhoneScreens()

    private var viewers: [String: PhoneViewer] = [:]
    private var sweep: Timer?

    private func viewer(_ pane: String) -> PhoneViewer {
        if let v = viewers[pane] { return v }
        let v = PhoneViewer(pane: pane)
        viewers[pane] = v
        if sweep == nil {
            sweep = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                MainActor.assumeIsolated { PhoneScreens.shared.letGo() }
            }
        }
        return v
    }

    /// Viewers the phone stopped asking about.
    private func letGo() {
        for (pane, v) in viewers where Date().timeIntervalSince(v.used) > 30 {
            v.close()
            viewers[pane] = nil
        }
        if viewers.isEmpty { sweep?.invalidate(); sweep = nil }
    }

    /// A window on this Mac has this terminal open: it keeps its size until
    /// the phone takes it.
    private func inWindow(_ pane: String) -> Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == "terminal:" + pane && $0.isVisible }
    }

    func handle(_ method: String, _ p: [String: Any]) async -> [String: Any] {
        let pane = p["terminal"] as? String ?? ""
        guard HerdrCore.isCore(pane) else { return ["ok": false, "error": "not a herdr-core terminal"] }
        let v = viewer(pane)
        v.used = Date()
        do {
            switch method {
            case "screen":
                try await v.open()
                return ["ok": true, "text": v.ansi()]
            case "type":
                try await v.open(active: true)
                v.type(p["text"] as? String ?? "")
                return ["ok": true]
            case "control":
                let take = (p["take"] as? Bool) == true
                if !take && !v.sized && inWindow(pane) {
                    try await v.open()
                    return ["ok": false, "held": true]
                }
                try await v.open(active: true)
                if let cols = p["cols"] as? Int, let rows = p["rows"] as? Int, cols > 0, rows > 0 { v.size(cols: cols, rows: rows) }
                if let dir = p["scroll"] as? String, dir == "up" || dir == "down" { v.scroll(up: dir == "up", lines: p["n"] as? Int ?? 3) }
                return ["ok": true, "held": false]
            default:
                return ["ok": false, "error": "unknown method \(method)"]
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}

@MainActor
final class PhoneViewer: TerminalDelegate {
    let pane: String
    var used = Date()
    /// The phone set its size (or typed): it is an active viewer.
    private(set) var sized = false
    private var active = false
    private var stream: CoreStream?
    private var opening: Task<Void, Error>?
    private lazy var term = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 24, scrollback: 2000))

    init(pane: String) { self.pane = pane }

    /// Attached (watching, or `active`: typing and sizing too). A watcher
    /// opens at the terminal's own size, so looking never resizes it. One
    /// opening at a time: a request that arrives meanwhile waits for it.
    func open(active want: Bool = false) async throws {
        while let opening { _ = try? await opening.value }
        if stream != nil && (active || !want) { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            stream?.close()
            stream = nil
            let t = try await HerdrCore.call("terminal.get", ["terminal": pane])
            let cols = max(20, t["cols"] as? Int ?? 80), rows = max(5, t["rows"] as? Int ?? 24)
            term = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 2000))
            let s = try await CoreLink.shared.attach(pane, cols: cols, rows: rows, history: 500, observe: !want)
            s.start(data: { [weak self] d in self?.term.feed(byteArray: [UInt8](d)) },
                    closed: { [weak self, weak s] _ in
                        guard let self, self.stream === s else { return }
                        self.stream = nil
                        self.active = false
                    })
            stream = s
            active = want
        }
        opening = task
        defer { opening = nil }
        try await task.value
    }

    func close() {
        stream?.close()
        stream = nil
    }

    func type(_ text: String) {
        sized = true
        stream?.write(Data(text.utf8))
    }

    func size(cols: Int, rows: Int) {
        sized = true
        guard cols != term.cols || rows != term.rows else { return }
        term.resize(cols: cols, rows: rows)
        stream?.resize(cols: cols, rows: rows)
    }

    /// A swipe: wheel events for a program that takes the mouse, arrows in
    /// a full-screen one that doesn't. A shell's own scrollback isn't kept
    /// here: the phone shows its recent screen.
    func scroll(up: Bool, lines: Int) {
        let n = min(max(lines, 1), 12)
        var bytes = ""
        if term.mouseMode != .off {
            // SGR wheel at the middle of the screen.
            let b = up ? 64 : 65
            bytes = String(repeating: "\u{1b}[<\(b);\(term.cols / 2);\(term.rows / 2)M", count: n)
        } else if term.isCurrentBufferAlternate {
            let k = term.applicationCursor ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B")
            bytes = String(repeating: k, count: n)
        }
        if !bytes.isEmpty { stream?.write(Data(bytes.utf8)) }
    }

    /// The screen as ANSI text, row by row: what herdr's ansi read gave the
    /// phone. (Scrollback stays the core's: its text reads have it.)
    func ansi() -> String {
        var out: [String] = []
        for r in 0..<term.rows {
            guard let line = term.getLine(row: r) else { continue }
            out.append(Self.row(line, cols: term.cols))
        }
        while out.count > 1, out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// The terminal's own colors and no style: SwiftTerm writes either
    /// default for the background of an empty cell.
    private static func plain(_ a: Attribute) -> Bool {
        a.style.isEmpty && a.fg == .defaultColor && (a.bg == .defaultColor || a.bg == .defaultInvertedColor)
    }

    private static func row(_ line: BufferLine, cols: Int) -> String {
        var s = ""
        var attr = Attribute.empty
        var styled = false
        var pendingSpaces = 0
        for c in 0..<min(cols, line.count) {
            let cell = line[c]
            if cell.width == 0 { continue }
            let ch = cell.getCharacter()
            let a = cell.attribute
            // Spaces on the plain background: written only if something follows.
            if (ch == " " || ch == "\u{0}") && !a.style.contains(.inverse) && (a.bg == .defaultColor || a.bg == .defaultInvertedColor)
                && a.style.intersection([.underline, .crossedOut]).isEmpty {
                pendingSpaces += 1
                continue
            }
            if pendingSpaces > 0 {
                // Plain spaces look the same in a style that only colors
                // text: reset only one that would show on them.
                let shows = !(attr.bg == .defaultColor || attr.bg == .defaultInvertedColor)
                    || !attr.style.intersection([.inverse, .underline, .crossedOut]).isEmpty
                if styled && shows { s += "\u{1b}[0m"; styled = false; attr = .empty }
                s += String(repeating: " ", count: pendingSpaces)
                pendingSpaces = 0
            }
            if plain(a) {
                if styled { s += "\u{1b}[0m"; styled = false; attr = .empty }
            } else if !styled || a != attr {
                s += sgr(a)
                attr = a
                styled = true
            }
            s.append(ch == "\u{0}" ? " " : ch)
        }
        if styled { s += "\u{1b}[0m" }
        return s
    }

    private static func sgr(_ a: Attribute) -> String {
        var p = ["0"]
        let st = a.style
        if st.contains(.bold) { p.append("1") }
        if st.contains(.dim) { p.append("2") }
        if st.contains(.italic) { p.append("3") }
        if st.contains(.underline) { p.append("4") }
        if st.contains(.inverse) { p.append("7") }
        if st.contains(.invisible) { p.append("8") }
        if st.contains(.crossedOut) { p.append("9") }
        p += color(a.fg, fg: true)
        p += color(a.bg, fg: false)
        return "\u{1b}[" + p.joined(separator: ";") + "m"
    }

    private static func color(_ c: Attribute.Color, fg: Bool) -> [String] {
        switch c {
        case .ansi256(let code):
            if code < 8 { return [String((fg ? 30 : 40) + Int(code))] }
            if code < 16 { return [String((fg ? 90 : 100) + Int(code) - 8)] }
            return [fg ? "38" : "48", "5", String(code)]
        case .trueColor(let r, let g, let b):
            return [fg ? "38" : "48", "2", String(r), String(g), String(b)]
        case .defaultColor, .defaultInvertedColor:
            return []
        }
    }

    // MARK: TerminalDelegate

    /// Its answers to the program's queries (the core answers most itself):
    /// sent on only by an active viewer, as a window's would be.
    nonisolated func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        Task { @MainActor in if self.active { self.stream?.write(bytes) } }
    }

    nonisolated func showCursor(source: Terminal) {}
    nonisolated func hideCursor(source: Terminal) {}
    nonisolated func setTerminalTitle(source: Terminal, title: String) {}
    nonisolated func setTerminalIconTitle(source: Terminal, title: String) {}
    nonisolated func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    nonisolated func sizeChanged(source: Terminal) {}
    nonisolated func scrolled(source: Terminal, yDisp: Int) {}
    nonisolated func linefeed(source: Terminal) {}
    nonisolated func bufferActivated(source: Terminal) {}
    nonisolated func bell(source: Terminal) {}
}

/// <support>/link.sock: reflexd's way to the app for what only the app has
/// (the phone's screens of herdr-core terminals).
final class AppLink: @unchecked Sendable {
    static let shared = AppLink()
    /// <support>/link.sock, or, when that path is too long for a socket (a
    /// profile in a deep folder), a short one in the app's temporary folder.
    /// reflexd is told which (REFLEX_LINK_SOCKET).
    static var path: String {
        let p = Settings.supportDir.appendingPathComponent("link.sock").path
        guard p.utf8.count >= 100 else { return p }
        // FNV-1a: the same folder gets the same name every launch.
        let tag = String(p.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }, radix: 16)
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("reflex-link-\(tag).sock")
    }

    private var fd: Int32 = -1

    func start() {
        guard fd < 0 else { return }
        let path = Self.path
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("Reflex: the app link's socket path is too long: %@", path)
            close(s)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { b in b.copyBytes(from: bytes); b[bytes.count] = 0 }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Yours alone: it types into your agents.
        chmod(path, 0o600)
        guard bound == 0, listen(s, 16) == 0 else {
            NSLog("Reflex: the app link couldn't listen on %@ (%d)", path, errno)
            close(s)
            return
        }
        fd = s
        let t = Thread { [weak self] in self?.accept() }
        t.name = "reflex.applink"
        t.start()
    }

    func stop() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
        unlink(Self.path)
    }

    private func accept() {
        while fd >= 0 {
            let c = Darwin.accept(fd, nil, nil)
            guard c >= 0 else { if errno == EINTR { continue } else { break } }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { Self.serve(c) }
        }
    }

    private static func serve(_ c: Int32) {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while line.last != 0x0a, line.count < 1 << 20 {
            let n = read(c, &chunk, chunk.count)
            guard n > 0 else { break }
            line.append(contentsOf: chunk[0..<n])
        }
        let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let method = req["method"] as? String ?? ""
        nonisolated(unsafe) let params = req["params"] as? [String: Any] ?? [:]
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply: [String: Any] = [:]
        Task { @MainActor in
            reply = await PhoneScreens.shared.handle(method, params)
            done.signal()
        }
        if done.wait(timeout: .now() + 8) == .timedOut { reply = ["ok": false, "error": "the app didn't answer in time"] }
        var out = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"ok":false}"#.utf8)
        out.append(0x0a)
        out.withUnsafeBytes { _ = write(c, $0.baseAddress, $0.count) }
        close(c)
    }
}
