import Foundation

@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
}
enum Motion { static let enter = 0 }
func withAnimation(_ animation: Int, _ body: () -> Void) { body() }
enum HerdrCore {
    struct Failure: Error { let kind: String }
    static func isCore(_ pane: String) -> Bool { true }
}

@MainActor final class TestWindow { var isKeyWindow = true }
@MainActor final class AgentTerminalView {
    let window: TestWindow? = TestWindow()
    var ownGrid: (cols: Int, rows: Int)
    var pinned: (cols: Int, rows: Int)?
    var onInput: ((ArraySlice<UInt8>) -> Bool)?
    var onResize: ((Int, Int) -> Void)?
    var onFocus: ((Bool) -> Void)?
    var frames: [String] = []
    init(cols: Int, rows: Int) { ownGrid = (cols, rows) }
    func pin(_ size: (cols: Int, rows: Int)?) { pinned = size }
    func feed(text: String) {}
    func resetKeys() {}
    func feed(byteArray: ArraySlice<UInt8>) { frames.append(String(decoding: byteArray, as: UTF8.self)) }
    func resize(_ cols: Int, _ rows: Int) {
        ownGrid = (cols, rows)
        pinned = nil
        onResize?(cols, rows)
    }
    func type(_ text: String) { _ = onInput?(Array(text.utf8)[...]) }
}

// The server models only protocol side effects: active attach, resize, focus
// and keys elect the latest controller; observe attaches never elect one.
@MainActor final class CoreLink {
    static let shared = CoreLink()
    var streams: [CoreStream] = []
    var size = (cols: 200, rows: 120)
    var owner: CoreStream?
    var serial = 0
    var resizes: [String] = []
    var actions: [String] = []
    var activeAttaches = 0
    var observerAttaches = 0
    var holdNextObserver = false
    var held: (stream: CoreStream, continuation: CheckedContinuation<Void, Never>)?
    var holdNextFrame = false
    var unpainted: CoreStream?

    func attach(_ pane: String, cols: Int, rows: Int, history: Int,
                observe: Bool = false, display: [String: Any] = [:]) async throws -> CoreStream {
        let s = CoreStream(core: self, cols: cols, rows: rows, observe: observe)
        streams.append(s)
        if observe {
            observerAttaches += 1
            if holdNextObserver {
                holdNextObserver = false
                await withCheckedContinuation { held = (s, $0) }
            }
            if holdNextFrame { holdNextFrame = false; s.holdFrame = true; unpainted = s }
        } else {
            activeAttaches += 1
            activate(s, action: "attach")
        }
        return s
    }
    func subscribe(_ pane: String) async throws -> CoreStream {
        let s = CoreStream(core: self, cols: 0, rows: 0, observe: true)
        s.subscription = true
        streams.append(s)
        return s
    }
    func activate(_ s: CoreStream, action: String) {
        precondition(!s.observe && !s.closed)
        serial += 1
        s.activity = serial
        owner = s
        actions.append(action)
        setSize(s.cols, s.rows)
    }
    func setSize(_ cols: Int, _ rows: Int) {
        guard size != (cols, rows) else { return }
        size = (cols, rows)
        resizes.append("\(cols)x\(rows)")
        let event = Data("{\"params\":{\"type\":\"size\",\"data\":{\"cols\":\(cols),\"rows\":\(rows)}}}\n".utf8)
        for s in streams where s.subscription && !s.closed {
            Task { @MainActor in if !s.closed { s.onData?(event) } }
        }
    }
    func release() -> CoreStream {
        let h = held!
        held = nil
        h.continuation.resume()
        return h.stream
    }
    var live: [CoreStream] { streams.filter { !$0.closed } }
}

@MainActor final class CoreStream {
    unowned let core: CoreLink
    var cols: Int, rows: Int
    let observe: Bool
    var subscription = false, closed = false, holdFrame = false
    var activity = 0
    var onData: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    init(core: CoreLink, cols: Int, rows: Int, observe: Bool) {
        self.core = core; self.cols = cols; self.rows = rows; self.observe = observe
    }
    func start(data: @escaping (Data) -> Void, closed: @escaping (String) -> Void) {
        onData = data; onClose = closed
        if !subscription && !holdFrame { Task { @MainActor in paint() } }
    }
    func paint() {
        guard !closed else { return }
        onData?(Data("paint \(cols)x\(rows)".utf8))
    }
    func facts(_ facts: [String: Any]) {}
    func resize(cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
        core.activate(self, action: "resize \(cols)x\(rows)")
    }
    func focus(_ on: Bool) { if on { core.activate(self, action: "focus") } }
    func write(_ data: Data) { core.activate(self, action: "keys " + String(decoding: data, as: UTF8.self)) }
    func close() {
        guard !closed else { return }
        closed = true
        if core.owner === self {
            if let next = core.live.filter({ !$0.observe }).max(by: { $0.activity < $1.activity }) {
                core.activate(next, action: "fallback")
            } else { core.owner = nil; core.setSize(200, 120) }
        }
    }
}
