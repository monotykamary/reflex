import Foundation

// Who sizes a herdr-core terminal, as one view sees it. Any number of
// windows can view a terminal (on this Mac and on the one it runs on), and
// the one last typed in, resized or focused sets its size: its program then
// draws for that window's grid. A view whose grid is another size draws
// those bytes in the wrong places, and a program that redraws only what
// changed (pi, Claude Code) never paints over them: a footer drawn for the
// other window's height, a row left blank. A view's own resize has a smaller
// edge of the same: output already on its way was drawn for the old size.
//
// So a view follows the terminal's `size` events. Another window's size: it
// watches at that size (its grid pinned to it) until it is used again. Its
// own size back, or its own resize settled: a fresh paint from the core,
// whose screen is exact.

/// A blank view for a core paint, which writes only the rows that hold
/// something. SwiftTerm's reset (ESC c) keeps the alternate screen's rows,
/// and entering it again doesn't clear them: a program on it (pi, Claude
/// Code) painted again kept the old frame wherever the new one is blank — a
/// stale footer, a separator gone. So that screen is cleared, then the reset.
enum CorePaint {
    static let blank = "\u{1b}[?1049h\u{1b}[2J\u{1b}[?1049l\u{1b}c"
}

struct CoreSize {
    enum Step: Equatable {
        case stay
        /// Take a fresh paint at this view's size.
        case repaint
        /// Another window set this size: watch at it.
        case follow(cols: Int, rows: Int)
        /// The size is this view's again after another's.
        case own
    }

    /// Sizes this view asked for lately: their events are its own.
    private var asked: [(cols: Int, rows: Int, at: Date)] = []
    /// What arrived since the last paint was drawn for a size not this view's.
    private(set) var stale = false
    /// How long an asked-for size is remembered as this view's.
    static let memory: TimeInterval = 5

    /// This view sized the terminal (its window resized).
    mutating func ask(cols: Int, rows: Int, now: Date = Date()) {
        forget(now)
        asked.append((cols, rows, now))
        stale = true
    }

    /// The terminal's size changed to this. `own` is the grid this view's
    /// window holds; `following` whether it watches at another's size now;
    /// `headless` the size the core gives a terminal no window sizes.
    mutating func sized(cols: Int, rows: Int, own: (cols: Int, rows: Int), following: Bool,
                        headless: (cols: Int, rows: Int) = CoreSize.headless, now: Date = Date()) -> Step {
        forget(now)
        if cols == own.cols && rows == own.rows { return following ? .own : (stale ? .repaint : .stay) }
        // The window that had it let go, and no other sizes it: nobody's
        // using it, so this one takes it back rather than watch at that.
        if following && cols == headless.cols && rows == headless.rows { return .own }
        // One of this view's own on the way to its last (a window dragged),
        // which the paint at the end covers.
        if asked.contains(where: { $0.cols == cols && $0.rows == rows }) { return .stay }
        stale = true
        return .follow(cols: cols, rows: rows)
    }

    /// A fresh paint is drawn: the view is the core's screen again.
    mutating func painted() {
        stale = false
        asked = []
    }

    /// herdr-core's `headless` setting (~/.config/herdr-core/config.toml,
    /// "COLSxROWS"), 200×120 by default. A terminal on another Mac follows
    /// that Mac's setting; this Mac's stands in for it.
    static let headless: (cols: Int, rows: Int) = {
        let home = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let file = home.appendingPathComponent("herdr-core/config.toml")
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("headless") }),
           let value = line.split(separator: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")),
           case let parts = value.split(separator: "x"), parts.count == 2,
           let c = Int(parts[0]), let r = Int(parts[1]) {
            return (c, r)
        }
        return (200, 120)
    }()

    private mutating func forget(_ now: Date) {
        asked.removeAll { now.timeIntervalSince($0.at) > Self.memory }
    }
}
