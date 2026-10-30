import Darwin
import Foundation

// One framed connection to herdr-core, through `hc connect` (which finds the
// socket and starts the core when it isn't running), carrying terminal
// streams: the live terminal in an agent's window and the phone's screens.
//
// After `hello {framed: true}` every message is a frame:
//   [channel u32 LE][kind u8][len u32 LE][payload]
// Channel 0 carries JSON-RPC both ways; `terminal.attach` opens another for
// one terminal's stream: its first paint, then its program's raw output.
// Keys go back as DATA on that channel; RESIZE, FOCUS and FACTS say what the
// viewer is. Flow control is credit: the core sends 256 KiB, then as much as
// the viewer says it has consumed (CREDIT, sent once the bytes are drawn).
//
// Patterns from the Herdr app's client, which runs on this protocol: frames
// that arrive before their attach's reply is handled wait in `early`; one
// queue writes, so a stalled core never blocks the UI; a dropped connection
// ends every stream (`lost`), and a viewer reattaches when it wants to.

final class CoreLink: @unchecked Sendable {
    static let shared = CoreLink()

    enum Kind: UInt8 { case data = 0, credit = 1, close = 2, resize = 3, focus = 4, facts = 5 }

    private let lock = NSLock()
    private var process: Process?
    private var toCore: FileHandle?
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var streams: [UInt32: CoreStream] = [:]
    private var early: [UInt32: [(Kind, Data)]] = [:]
    /// Channels we closed (or never took): what still arrives on them is
    /// dropped, until the core's own CLOSE.
    private var closed = Set<UInt32>()
    private var nextID = 1
    /// One connection attempt at a time.
    private let connecting = NSLock()
    /// The session the connection was made for (see reset).
    private var session = ""
    private let writes = DispatchQueue(label: "reflex.corelink.write")

    // MARK: Connecting

    /// Connected now, or connects: false when the core can't be reached.
    private func connected() -> Bool {
        connecting.lock()
        defer { connecting.unlock() }
        lock.lock()
        if let p = process, p.isRunning { lock.unlock(); return true }
        lock.unlock()
        guard let bin = HerdrCore.binary() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["connect"]
        p.environment = HerdrCore.environment()
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        // A core that went away mid-write is an error here, not SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let hello = #"{"jsonrpc":"2.0","id":0,"method":"hello","params":{"framed":true}}"# + "\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(hello.utf8))
        let fromCore = output.fileHandleForReading
        // Its reply is one plain line; everything after it is framed.
        guard let line = Self.readLine(fromCore, timeout: 10), let v = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let r = v["result"] as? [String: Any], (r["framed"] as? Bool) == true else {
            NSLog("Reflex: herdr-core didn't open a framed connection")
            p.terminate()
            return false
        }
        if let g = r["generation"] as? Int, g != 1 {
            NSLog("Reflex: herdr-core speaks protocol generation %d; this Reflex knows 1", g)
        }
        lock.lock()
        process = p
        toCore = input.fileHandleForWriting
        session = HerdrCore.session
        lock.unlock()
        let reader = Thread { [weak self] in self?.read(fromCore, p) }
        reader.name = "reflex.corelink.read"
        reader.start()
        return true
    }

    /// The hello reply: one plain line, read a byte at a time so nothing
    /// framed after it is taken; nil if it doesn't come in `timeout` seconds.
    private static func readLine(_ h: FileHandle, timeout: TimeInterval) -> Data? {
        var line = Data()
        var c: UInt8 = 0
        let end = Date().addingTimeInterval(timeout)
        while true {
            var fd = pollfd(fd: h.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, end.timeIntervalSinceNow) * 1000)
            guard left > 0, poll(&fd, 1, left) == 1, Darwin.read(h.fileDescriptor, &c, 1) == 1 else { return nil }
            if c == 0x0a { return line }
            line.append(c)
        }
    }

    /// Drop the connection (another core session was chosen): streams end
    /// as lost, and the next call connects to the right core.
    func reset() {
        lock.lock()
        let p = process
        let stale = p != nil && session != HerdrCore.session
        lock.unlock()
        if stale, let p { p.terminate(); lost(p) }
    }

    // MARK: Frames

    private func read(_ h: FileHandle, _ p: Process) {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        // Whatever has arrived, until there is enough (a pipe's read returns
        // what is there; FileHandle's would wait to fill its count).
        func need(_ n: Int) -> Bool {
            while buf.count < n {
                let got = Darwin.read(h.fileDescriptor, &chunk, chunk.count)
                guard got > 0 else { return false }
                buf.append(contentsOf: chunk[0..<got])
            }
            return true
        }
        while true {
            guard need(9) else { break }
            let channel = buf.le32(0), kind = buf[buf.startIndex + 4], len = Int(buf.le32(5))
            guard need(9 + len) else { break }
            let payload = buf.subdata(in: (buf.startIndex + 9)..<(buf.startIndex + 9 + len))
            buf.removeSubrange(buf.startIndex..<(buf.startIndex + 9 + len))
            guard let k = Kind(rawValue: kind) else { continue }
            if channel == 0 {
                if k == .data { reply(payload) }
            } else {
                deliver(channel, k, payload)
            }
        }
        lost(p)
    }

    private func reply(_ payload: Data) {
        guard let v = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let id = v["id"] as? Int else { return }
        lock.lock()
        let done = pending.removeValue(forKey: id)
        lock.unlock()
        if let e = v["error"] as? [String: Any] {
            let data = e["data"] as? [String: Any]
            done?(.failure(HerdrCore.Failure(kind: data?["kind"] as? String ?? "error", message: e["message"] as? String ?? "herdr-core error")))
        } else {
            done?(.success(v["result"] as? [String: Any] ?? [:]))
        }
    }

    private func deliver(_ channel: UInt32, _ kind: Kind, _ payload: Data) {
        lock.lock()
        guard let s = streams[channel] else {
            if closed.contains(channel) {
                if kind == .close { closed.remove(channel) }
            } else {
                early[channel, default: []].append((kind, payload))
            }
            lock.unlock()
            return
        }
        if kind == .close { streams[channel] = nil }
        lock.unlock()
        s.got(kind, payload)
    }

    /// The connection dropped (the core restarted for an update, or quit):
    /// every stream ends, every call fails, and the next one reconnects.
    private func lost(_ p: Process) {
        lock.lock()
        guard process === p else { lock.unlock(); return }
        process = nil
        toCore = nil
        let calls = pending.values
        let open = streams.values
        pending = [:]
        streams = [:]
        early = [:]
        closed = []
        lock.unlock()
        calls.forEach { $0(.failure(HerdrCore.Failure(kind: "unavailable", message: "lost the connection to herdr-core"))) }
        open.forEach { $0.got(.close, Data(#"{"reason":"lost"}"#.utf8)) }
    }

    func send(_ channel: UInt32, _ kind: Kind, _ payload: Data) {
        var frame = Data(capacity: 9 + payload.count)
        frame.appendLE32(channel)
        frame.append(kind.rawValue)
        frame.appendLE32(UInt32(payload.count))
        frame.append(payload)
        writes.async { [weak self] in
            self?.lock.lock()
            let h = self?.toCore
            self?.lock.unlock()
            try? h?.write(contentsOf: frame)
        }
    }

    /// We closed it: drop what still comes on it.
    func forget(_ channel: UInt32) {
        lock.lock()
        streams[channel] = nil
        early[channel] = nil
        closed.insert(channel)
        lock.unlock()
    }

    // MARK: Calls

    /// A JSON-RPC call on channel 0. `opened` runs on the reader thread with
    /// the result before any later frame is read: an attach registers its
    /// stream there, so none of its bytes go astray.
    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 10,
              opened: ((([String: Any])) -> Void)? = nil) async throws -> [String: Any] {
        guard await Task.detached(operation: { self.connected() }).value else {
            throw HerdrCore.Failure(kind: "unavailable", message: "herdr-core isn't running or isn't installed")
        }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<[String: Any], Error>) in
            lock.lock()
            let id = nextID
            nextID += 1
            var finished = false
            pending[id] = { [weak self] r in
                if case .success(let v) = r {
                    // Answered after we gave up: a stream it opened has no
                    // viewer, so close it at the core.
                    if finished, let ch = (v["channel"] as? NSNumber)?.uint32Value, ch != 0 {
                        self?.send(ch, .close, Data())
                        self?.forget(ch)
                        return
                    }
                    opened?(v)
                }
                guard !finished else { return }
                finished = true
                k.resume(with: r)
            }
            lock.unlock()
            let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                lock.lock(); pending[id] = nil; lock.unlock()
                k.resume(throwing: HerdrCore.Failure(kind: "usage", message: "unencodable request"))
                return
            }
            send(0, .data, data)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.lock.lock()
                let late = self?.pending.removeValue(forKey: id)
                // Still waited on: a reply now is late (see above).
                if late != nil { self?.pending[id] = { [weak self] r in
                    if case .success(let v) = r, let ch = (v["channel"] as? NSNumber)?.uint32Value, ch != 0 {
                        self?.send(ch, .close, Data())
                        self?.forget(ch)
                    }
                } }
                self?.lock.unlock()
                late?(.failure(HerdrCore.Failure(kind: "timeout", message: "herdr-core didn't answer \(method)")))
            }
        }
    }

    /// Open a stream onto a terminal, at the viewer's size. `observe` only
    /// watches (never types or resizes); `history` lines of scrollback come
    /// first in the paint.
    func attach(_ terminal: String, cols: Int, rows: Int, history: Int = 0, observe: Bool = false,
                display: [String: Any] = [:]) async throws -> CoreStream {
        let stream = CoreStream(link: self)
        var params: [String: Any] = ["terminal": terminal, "cols": max(1, cols), "rows": max(1, rows),
                                     "history": history, "observe": observe]
        if !display.isEmpty { params["display"] = display }
        _ = try await call("terminal.attach", params) { [weak self] r in
            guard let self, let ch = (r["channel"] as? NSNumber)?.uint32Value else { return }
            self.lock.lock()
            stream.channel = ch
            self.streams[ch] = stream
            let before = self.early.removeValue(forKey: ch) ?? []
            self.lock.unlock()
            before.forEach { stream.got($0.0, $0.1) }
        }
        guard stream.channel != 0 else { throw HerdrCore.Failure(kind: "protocol", message: "attach opened no stream") }
        return stream
    }
}

/// One terminal's stream. Its handlers run on the main queue, in order:
/// what arrived before `start` first, then the rest.
final class CoreStream: @unchecked Sendable {
    fileprivate(set) var channel: UInt32 = 0
    private weak var link: CoreLink?
    private var buffered: [(CoreLink.Kind, Data)] = []
    private let lock = NSLock()
    private var started = false
    /// Main queue only.
    private var ended = false
    private var onData: ((Data) -> Void)?
    private var onClose: ((String) -> Void)?

    fileprivate init(link: CoreLink) { self.link = link }

    /// `data`: the program's output (credited back once it returns).
    /// `closed`: why it ended — "exited", "killed", "lost" (the program, or
    /// our line to the core: reattach once it is back), "detached".
    func start(data: @escaping (Data) -> Void, closed: @escaping (String) -> Void) {
        lock.lock()
        onData = data
        onClose = closed
        started = true
        // Queued while holding the lock: nothing live can overtake them.
        buffered.forEach(enqueue)
        buffered = []
        lock.unlock()
    }

    fileprivate func got(_ kind: CoreLink.Kind, _ payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        if started { enqueue((kind, payload)) } else { buffered.append((kind, payload)) }
    }

    /// Called with `lock` held.
    private func enqueue(_ f: (CoreLink.Kind, Data)) {
        let (kind, payload) = f
        switch kind {
        case .data:
            DispatchQueue.main.async { [self] in
                guard !ended else { return }
                onData?(payload)
                send(.credit, Data(le32: UInt32(payload.count)))
            }
        case .close:
            let reason = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["reason"] as? String
            DispatchQueue.main.async { [self] in
                guard !ended else { return }
                ended = true
                onClose?(reason ?? "detached")
            }
        default:
            break
        }
    }

    private func send(_ kind: CoreLink.Kind, _ payload: Data) {
        guard channel != 0, !ended else { return }
        link?.send(channel, kind, payload)
    }

    /// Keys, typed as the program expects them (the terminal view encodes them).
    func write(_ bytes: Data) { send(.data, bytes) }

    func resize(cols: Int, rows: Int) {
        var d = Data()
        d.appendLE16(UInt16(clamping: max(1, cols)))
        d.appendLE16(UInt16(clamping: max(1, rows)))
        send(.resize, d)
    }

    func focus(_ on: Bool) { send(.focus, Data([on ? 1 : 0])) }

    /// The viewer's colors and cell size (`Display`): send before a resize,
    /// so a program woken by it reads the new cell size.
    func facts(_ display: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: display) else { return }
        send(.facts, d)
    }

    func close() {
        guard channel != 0, !ended else { return }
        link?.send(channel, .close, Data())
        ended = true
        link?.forget(channel)
    }
}

extension Data {
    init(le32 v: UInt32) {
        self.init()
        appendLE32(v)
    }

    mutating func appendLE32(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE16(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    func le32(_ at: Int) -> UInt32 {
        let i = startIndex + at
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
