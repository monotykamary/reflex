import AppKit
import Testing
@testable import SwiftTerm

/// Regressions for inline TUI emulation mismatches between libghostty-vt
/// (herdr-core) and SwiftTerm 1.20.0 (Reflex): pending-wrap cursor/edit
/// commands, missing ECH/REP dirty ranges, split wide glyphs, and end-of-line
/// VS16 widening.
@Suite(.serialized)
final class InlineEmulationTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func terminal(cols: Int = 10, rows: Int = 5) -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows))
    }

    private func rowText(_ t: Terminal, _ row: Int) -> String {
        guard let line = t.getLine(row: row) else { return "" }
        var out = ""
        var col = 0
        while col < t.cols {
            let cd = line[col]
            let ch = t.getCharacter(for: cd)
            if ch == "\u{0}" {
                out.append(" ")
                col += 1
            } else {
                out.append(ch)
                col += max(1, Int(cd.width))
            }
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    @Test func pendingWrapCursorUpAndVPAClearPendingWrap() {
        let t1 = terminal()
        t1.feed(text: "0123456789\r\n" + String(repeating: "─", count: 10) + "\u{1b}[1AZ")
        #expect(rowText(t1, 0) == "012345678Z")
        #expect(rowText(t1, 1) == String(repeating: "─", count: 10))

        let t2 = terminal()
        t2.feed(text: "0123456789\r\nABCDEFGHIJ\u{1b}[1dZ")
        #expect(rowText(t2, 0) == "012345678Z")
        #expect(rowText(t2, 1) == "ABCDEFGHIJ")
    }

    @Test func pendingWrapCursorBackwardMovesFromLastColumn() {
        let t1 = terminal()
        t1.feed(text: "ABCDEFGHIJ\u{1b}[1DZ")
        #expect(rowText(t1, 0) == "ABCDEFGHZJ")
        #expect(t1.getCursorLocation() == (9, 0))

        let t2 = terminal()
        t2.feed(text: "ABCDEFGHIJ\u{1b}[3DZ")
        #expect(rowText(t2, 0) == "ABCDEFZHIJ")
        #expect(t2.getCursorLocation() == (7, 0))
    }

    @Test func pendingWrapEraseInsertAndDeleteTargetLastColumn() {
        let el = terminal()
        el.feed(text: "ABCDEFGHIJ\u{1b}[K")
        #expect(rowText(el, 0) == "ABCDEFGHI")

        let ed = terminal()
        ed.feed(text: "ABCDEFGHIJ\u{1b}[J")
        #expect(rowText(ed, 0) == "ABCDEFGHI")

        let ech = terminal()
        ech.feed(text: "ABCDEFGHIJ\u{1b}[1X")
        #expect(rowText(ech, 0) == "ABCDEFGHI")

        let dch = terminal()
        dch.feed(text: "ABCDEFGHIJ\u{1b}[1P")
        #expect(rowText(dch, 0) == "ABCDEFGHI")

        let ich = terminal()
        ich.feed(text: "ABCDEFGHIJ\u{1b}[1@")
        #expect(rowText(ich, 0) == "ABCDEFGHI")
    }

    @Test func echAndRepMarkDirtyRowsForRedraw() {
        let ech = terminal()
        ech.feed(text: "hello")
        ech.clearUpdateRange()
        ech.feed(text: "\r\u{1b}[3X")
        #expect(ech.getUpdateRange() != nil)
        #expect(rowText(ech, 0) == "   lo")

        let rep = terminal()
        rep.feed(text: "─")
        rep.clearUpdateRange()
        rep.feed(text: "\u{1b}[4b")
        #expect(rep.getUpdateRange() != nil)
        #expect(rowText(rep, 0) == "─────")
    }

    @Test func overwritingOrErasingWideGlyphHalvesClearsCompanionCell() {
        // Right half overwrite via ASCII fast path
        let rightAscii = terminal()
        rightAscii.feed(text: "🔥X\r\u{1b}[1CA")
        #expect(rowText(rightAscii, 0) == " AX")

        // Right half overwrite via non-ASCII path
        let rightUnicode = terminal()
        rightUnicode.feed(text: "🔥X\r\u{1b}[1C─")
        #expect(rowText(rightUnicode, 0) == " ─X")

        // Left half overwrite leaves a clean width-1 blank at col 1
        let left = terminal()
        left.feed(text: "🔥X\rA")
        #expect(rowText(left, 0) == "A X")
        #expect(left.getLine(row: 0)?[1].width == 1)

        // ECH on right half clears the leading wide cell too
        let echRight = terminal()
        echRight.feed(text: "🔥X\r\u{1b}[1C\u{1b}[1X")
        #expect(rowText(echRight, 0) == "  X")

        // ECH on left half clears the trailing placeholder too
        let echLeft = terminal()
        echLeft.feed(text: "🔥X\r\u{1b}[1X")
        #expect(rowText(echLeft, 0) == "  X")
        #expect(echLeft.getLine(row: 0)?[1].width == 1)

        // Wide glyph at right edge + pending-wrap CUU / CUB
        let wideCuu = terminal()
        wideCuu.feed(text: "line0\r\n01234567🔥\u{1b}[1AZ")
        #expect(rowText(wideCuu, 0) == "line0    Z")
        #expect(rowText(wideCuu, 1) == "01234567🔥")

        let wideCub = terminal()
        wideCub.feed(text: "01234567🔥\u{1b}[1DZ")
        #expect(rowText(wideCub, 0) == "01234567Z")
    }

    @Test func repRepeatsWideGlyphNotTrailingPlaceholder() {
        let t = terminal()
        t.feed(text: "🔥\u{1b}[2bX")
        #expect(rowText(t, 0) == "🔥🔥🔥X")
        #expect(t.getCursorLocation() == (7, 0))
    }

    @Test func vs16AtLastColumnWrapsWideGlyphToNextRow() {
        let t = terminal()
        t.feed(text: "012345678\u{26A0}\u{FE0F}Z")
        #expect(rowText(t, 0) == "012345678")
        #expect(rowText(t, 1) == "\u{26A0}\u{FE0F}Z")
        #expect(t.getCursorLocation() == (3, 1))
    }

    @Test func combiningMarkWithScrollbackMarksScreenRow() {
        let t = terminal(cols: 10, rows: 3)
        t.feed(text: "L0\r\nL1\r\nL2\r\nL3\r\ne")
        t.clearUpdateRange()
        t.feed(text: "\u{0301}")
        let range = t.getUpdateRange()
        #expect(range?.startY == 2 && range?.endY == 2)
    }

    @MainActor
    @Test func wideRightHalfOverwriteRendersNewGlyphInTerminalView() {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        view.feed(text: "🔥X\r\u{1b}[1CA")
        let t = view.getTerminal()
        let info = view.buildAttributedString(row: 0, line: t.displayBuffer.lines[0], cols: t.cols)
        let rendered = info.segments.map(\.attributedString.string).joined()
        #expect(!rendered.contains("🔥"))
        #expect(rendered.hasPrefix(" AX"))
    }
}
