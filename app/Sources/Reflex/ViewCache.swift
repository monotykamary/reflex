import Foundation

/// What a settings page showed last, kept on disk so it opens with that
/// (stale-while-revalidate) rather than empty while the fresh data loads.
/// For display only: nothing decides anything from it.
enum ViewCache {
    private static func url(_ name: String) -> URL {
        Settings.supportDir.appendingPathComponent("view-cache-\(name).json")
    }

    static func load<T: Decodable>(_ name: String, as: T.Type = T.self) -> T? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ name: String, _ value: T) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        try? d.write(to: url(name), options: .atomic)
    }
}
