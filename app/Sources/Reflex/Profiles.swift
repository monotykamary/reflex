import Foundation

/// Harness profiles (`reflex profile`): one harness signed in to another
/// account, named "claude[tom]". Its login and sessions are its own (in
/// ~/.reflex/profiles/<harness>/<name>/), everything else is shared. Reflex
/// starts an agent in one through `reflex profile run`, so a machine's
/// default profile applies to a bare "claude" there too.
enum Profiles {
    /// "claude" with nil or "" → "claude"; with "tom" → "claude[tom]".
    static func spec(_ kind: String, _ profile: String?) -> String {
        guard let p = profile, !p.isEmpty else { return kind }
        return "\(kind)[\(p)]"
    }

    /// "claude[tom]" → ("claude", "tom"); "claude" → ("claude", "").
    static func split(_ spec: String) -> (kind: String, profile: String) {
        guard spec.hasSuffix("]"), let open = spec.firstIndex(of: "[") else { return (spec, "") }
        return (String(spec[..<open]), String(spec[spec.index(after: open)..<spec.index(before: spec.endIndex)]))
    }

    /// Whether a session or agent is what "/claude" or "/claude[tom]" picks:
    /// a bare harness any of its, a profile only that profile's.
    static func matches(_ wanted: String, kind: String, profile: String?) -> Bool {
        let (k, p) = split(wanted)
        guard k == kind else { return false }
        return p.isEmpty || p == (profile ?? "")
    }

    /// This Mac's profiles, as specs, sorted.
    static func local() -> [String] {
        let root = NSHomeDirectory() + "/.reflex/profiles"
        let fm = FileManager.default
        var out: [String] = []
        for h in ["claude", "codex", "agy", "pi", "opencode", "amp", "grok"] {  // (reflex profile's)
            let names = (try? fm.contentsOfDirectory(atPath: "\(root)/\(h)")) ?? []
            for n in names.sorted() where !n.hasPrefix(".") {
                var dir: ObjCBool = false
                if fm.fileExists(atPath: "\(root)/\(h)/\(n)", isDirectory: &dir), dir.boolValue { out.append(spec(h, n)) }
            }
        }
        return out
    }

    /// What new sessions can start with: each harness's profiles where it has
    /// any (profiles only: a bare "agy" is not offered beside "agy[tom]"),
    /// the bare harness where it has none.
    static func choices() -> [String] {
        let profiles = local()
        return Onboarding.harnesses.flatMap { h -> [String] in
            let mine = profiles.filter { split($0).kind == h }
            return mine.isEmpty ? [h] : mine
        } + profiles.filter { !Onboarding.harnesses.contains(split($0).kind) }
    }

    /// This Mac's default profile for each harness (`reflex profile default`:
    /// ~/.reflex/profiles/defaults, "claude tom" lines).
    static func defaults() -> [String: String] {
        let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.reflex/profiles/defaults", encoding: .utf8)) ?? ""
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let w = line.split(separator: " ", omittingEmptySubsequences: true)
            if w.count == 2 { out[String(w[0])] = String(w[1]) }
        }
        return out
    }

    /// A stored default as one of `choices()`: a bare harness that has
    /// profiles becomes its default profile (else its first); a profile
    /// that is gone becomes its harness's.
    static func resolve(_ stored: String) -> String {
        let options = choices()
        if options.contains(stored) { return stored }
        let kind = split(stored).kind
        let mine = options.filter { split($0).kind == kind }
        if let d = defaults()[kind], mine.contains(spec(kind, d)) { return spec(kind, d) }
        return mine.first ?? options.first ?? stored
    }
}
