import Foundation

// Foundation-only stand-ins let the production machine code run on Linux too.
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

enum Settings {
    static let supportDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACHINE_TEST_ROOT"]!)
}
@MainActor final class Daemon {
    static let shared = Daemon()
    func childEnvironment() -> [String: String] { HerdrCore.environment }
}
final class RemoteIndex {
    static let shared = RemoteIndex()
    private let lock = NSLock()
    private var count = 0
    var refreshes: Int { lock.withLock { count } }
    func refresh() { lock.withLock { count += 1 } }
}

enum HerdrCore {
    struct Failure: Error, LocalizedError {
        let kind: String
        let message: String
        var errorDescription: String? { message }
    }
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Settings.supportDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }
    static func run(_ args: [String], timeout: TimeInterval) -> (status: Int32, out: String, err: String) {
        MachineSetup.run(environment, Settings.supportDir.appendingPathComponent("hc").path, args, timeout: timeout)
    }
    private static let lock = NSLock()
    private static var hold = false
    private static var pending: CheckedContinuation<Void, Never>?
    static func holdNextList() { lock.withLock { hold = true } }
    static var listWaiting: Bool { lock.withLock { pending != nil } }
    static func releaseList() {
        let saved = lock.withLock { let saved = pending; pending = nil; return saved }
        saved?.resume()
    }
    static func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        precondition(method == "machine.list", "Unexpected RPC: \(method)")
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: Settings.supportDir.appendingPathComponent("hc.json")))
        let wait = lock.withLock { let wait = hold; hold = false; return wait }
        if wait { await withCheckedContinuation { continuation in lock.withLock { pending = continuation } } }
        return ["machines": rows]
    }
    static func callSync(_ method: String, _ params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        fatalError("No remote commands should run in a removal test")
    }
}
