import Foundation

/// Blocking work (a subprocess waited on, a socket read, a long file read)
/// off Swift's cooperative pool. That pool has a thread per core, and every
/// `await` in the app needs one: blocking calls run as detached tasks there
/// (four machine listeners holding `hc exec` open, a `reflex home run`)
/// starved it, and windows waiting to attach to herdr-core stayed blank until
/// a thread came free. GCD grows its threads for blocked work instead.
enum Blocking {
    static let queue = DispatchQueue(label: "reflex.blocking", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { k in queue.async { k.resume(returning: work()) } }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { k in queue.async { k.resume(with: Result { try work() }) } }
    }
}
