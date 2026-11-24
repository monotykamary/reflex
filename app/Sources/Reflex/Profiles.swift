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
}
