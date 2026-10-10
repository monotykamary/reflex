import Foundation

// What Jev should know beyond the one request in front of it:
//
//   sends        where your last few requests went, so "also add tests
//                there" lands in the session the last one did
//   corrections  where you overrode Jev's pick, so a similar request goes
//                where you sent it next time
//
// Kept in the app (memory.json in the support folder, a few KB) and sent
// with each request as a few lines Jev reads with the rest of the state.

@MainActor
final class Memory {
    static let shared = Memory()

    struct Send: Codable {
        var at: Date
        var text: String
        var target: String
    }

    struct Correction: Codable {
        var at: Date
        var text: String
        var jev: String
        var chose: String
    }

    private struct File: Codable {
        var sends: [Send] = []
        var corrections: [Correction] = []
    }

    private var file = File()
    private let url = Settings.supportDir.appendingPathComponent("memory.json")

    var corrections: Int { file.corrections.count }

    init() {
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) { file = f }
    }

    func sent(_ text: String, to target: String) {
        file.sends.append(Send(at: Date(), text: text, target: target))
        file.sends = Array(file.sends.suffix(40))
        save()
    }

    func corrected(_ text: String, jev: String, chose: String) {
        file.corrections.append(Correction(at: Date(), text: text, jev: jev, chose: chose))
        file.corrections = Array(file.corrections.suffix(200))
        save()
    }

    func forget() {
        file = File()
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(file) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: What Jev reads

    /// The lines that matter for `request`: the last few sends of the past
    /// six hours, newest first, and up to three corrections for similar
    /// requests. Empty when there is nothing worth saying.
    func context(for request: String, now: Date = Date()) -> String {
        var out = ""
        for s in file.sends.reversed().prefix(4) where now.timeIntervalSince(s.at) < 6 * 3600 {
            out += "Sent \(Memory.ago(s.at, now)): \(Memory.quote(s.text)) → \(s.target)\n"
        }
        for c in similar(request) {
            out += "For \(Memory.quote(c.text)) Jev suggested \(c.jev); the user chose \(c.chose) instead\n"
        }
        return out
    }

    /// Corrections whose request shares enough words with this one: two, or
    /// one when either side is that short. The closest first, then the newest.
    func similar(_ request: String, limit: Int = 3) -> [Correction] {
        let words = Memory.tokens(request)
        guard !words.isEmpty else { return [] }
        return file.corrections.enumerated().compactMap { i, c -> (Correction, Int, Int)? in
            let theirs = Memory.tokens(c.text)
            let n = theirs.intersection(words).count
            let needed = min(words.count, theirs.count) <= 2 ? 1 : 2
            return n >= needed ? (c, n, i) : nil
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
        .prefix(limit).map(\.0)
    }

    /// Words that say what a request is about: lowercased, 3+ letters, a
    /// plural's "s" off, without the words every request has.
    static func tokens(_ text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(parts.compactMap { p -> String? in
            var w = String(p)
            guard w.count >= 3, !stop.contains(w) else { return nil }
            if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
            return w
        })
    }

    private static let stop: Set<String> = [
        "the", "and", "for", "with", "that", "this", "these", "those", "there", "here", "then", "than",
        "can", "you", "your", "please", "could", "would", "should", "will", "just", "also", "again",
        "same", "now", "some", "any", "all", "but", "not", "are", "was", "were", "has", "have", "had",
        "its", "into", "from", "out", "about", "what", "why", "how", "when", "where", "which", "who",
        "let", "lets", "make", "add", "fix", "update", "change", "check", "run", "use", "get", "set",
        "new", "one", "more", "too", "very", "really", "still", "need", "want", "like", "via",
    ]

    private static func quote(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return "\"" + (t.count > 140 ? String(t.prefix(140)) + "…" : t) + "\""
    }

    private static func ago(_ d: Date, _ now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    /// A folder as Jev sees folders: under the home directory, with "~".
    static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
