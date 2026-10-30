// Stands in for the app's HerdrCore: just what CoreLink needs, from the environment.
import Foundation
enum HerdrCore {
    static func binary() -> String? { ProcessInfo.processInfo.environment["HC_BIN"] }
    static var session: String { ProcessInfo.processInfo.environment["HC_SESSION"] ?? "default" }
    static func environment() -> [String: String] { ProcessInfo.processInfo.environment }
    struct Failure: Error, LocalizedError { let kind: String; let message: String; var errorDescription: String? { "\(kind): \(message)" } }
}
