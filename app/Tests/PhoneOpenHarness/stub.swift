// A controlled core: suspend the first get so several phone requests share
// one opening task, then complete it together. Never starts a real core.
import Foundation

// Rendering is outside this regression. Only the viewer's lifecycle methods
// are compiled from PhoneLink.swift; the terminal is never fed or inspected.
@MainActor protocol TerminalDelegate: AnyObject {}
struct TerminalOptions { let cols: Int; let rows: Int; let scrollback: Int }
@MainActor final class Terminal {
    init(delegate: TerminalDelegate, options: TerminalOptions) {}
    func feed(byteArray: [UInt8]) {}
}

@MainActor
enum HerdrCore {
    enum Failure: Error { case unavailable }
    static var gets = 0
    static var hold = false
    static var fail = false
    static var waiting: CheckedContinuation<Void, Never>?
    static func isCore(_ pane: String) -> Bool { !pane.isEmpty && !pane.contains(":") }
    static func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        gets += 1
        if hold {
            hold = false
            await withCheckedContinuation { waiting = $0 }
        }
        if fail { fail = false; throw Failure.unavailable }
        return ["cols": 80, "rows": 24]
    }
    static func release() { let w = waiting; waiting = nil; w?.resume() }
}

@MainActor
final class CoreLink {
    static let shared = CoreLink()
    var attaches = 0
    var modes: [Bool] = []
    func attach(_ pane: String, cols: Int, rows: Int, history: Int, observe: Bool) async throws -> CoreStream {
        attaches += 1
        modes.append(observe)
        return CoreStream()
    }
}

@MainActor
final class CoreStream {
    func start(data: @escaping (Data) -> Void, closed: @escaping (String) -> Void) {}
    func close() {}
    func write(_ bytes: Data) {}
    func resize(cols: Int, rows: Int) {}
}

enum Settings {
    static var supportDir: URL { FileManager.default.temporaryDirectory }
}
