// Stands in for the app around PhoneLink: HerdrCore (through CoreLink's own
// connection), Settings.supportDir from the environment.
import Foundation

enum HerdrCore {
    static func binary() -> String? { ProcessInfo.processInfo.environment["HC_BIN"] }
    static var session: String { ProcessInfo.processInfo.environment["HC_SESSION"] ?? "default" }
    static func environment() -> [String: String] { ProcessInfo.processInfo.environment }
    static func isCore(_ pane: String) -> Bool { !pane.isEmpty && !pane.contains(":") }
    struct Failure: Error, LocalizedError { let kind: String; let message: String; var errorDescription: String? { "\(kind): \(message)" } }
    static func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 5) async throws -> [String: Any] {
        try await CoreLink.shared.call(method, params, timeout: timeout)
    }
}

enum Settings {
    static var supportDir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["REFLEX_DATA"]!) }
}
