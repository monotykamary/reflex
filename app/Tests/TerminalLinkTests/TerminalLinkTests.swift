import AppKit
import Testing
@testable import SwiftTerm

/// Pi writes actual spaces to pad a TUI row, not just empty terminal cells.
/// These tests exercise the matcher and the native renderer used by Reflex.
@Suite(.serialized)
final class TerminalLinkTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func terminal(cols: Int = 100) -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: 4))
    }

    @Test(arguments: [
        ".local/discord-pilot/webhook.url",
        "./config.json", "../example.py", "/tmp/example.txt",
        "~/Library/config", "src/config/file.swift", "./space middle"
    ])
    func paddedPathsEndAtTheirLastCharacter(path: String) throws {
        let t = terminal()
        let prefix = "  chmod 600 "
        let end = prefix.count + path.count
        t.feed(text: "\u{1b}[?1049h" + prefix + path + String(repeating: " ", count: t.cols - end))

        for col in [prefix.count, end - 1] {
            let match = try #require(t.linkMatch(at: .screen(Position(col: col, row: 0)), mode: .explicitAndImplicit))
            #expect(match.text == path)
            #expect(match.range == prefix.count..<end)
            #expect(match.rowRanges == [.init(row: 0, range: prefix.count..<end)])
        }
        for col in [end, t.cols - 1] {
            #expect(t.link(at: .screen(Position(col: col, row: 0)), mode: .explicitAndImplicit) == nil)
        }
    }

    @Test func wrappedPathDoesNotUnderlineFinalRowPadding() throws {
        let t = terminal(cols: 20)
        let path = ".local/discord-pilot/webhook.url"
        let tail = path.count - t.cols
        t.feed(text: path + String(repeating: " ", count: t.cols - tail))
        let match = try #require(t.linkMatch(at: .screen(Position(col: 2, row: 1)), mode: .explicitAndImplicit))
        #expect(match.text == path)
        #expect(match.rowRanges == [.init(row: 0, range: 0..<20), .init(row: 1, range: 0..<tail)])
        #expect(t.link(at: .screen(Position(col: tail, row: 1)), mode: .explicitAndImplicit) == nil)
    }

    @Test func unpaddedPathStillMatches() throws {
        let t = terminal()
        let path = "../example.py"
        t.feed(text: path)
        let match = try #require(t.linkMatch(at: .screen(Position(col: 2, row: 0)), mode: .explicitAndImplicit))
        #expect(match.text == path)
        #expect(match.range == 0..<path.count)
    }

    @Test func webURLKeepsPunctuationAndPaddingOutsideLink() throws {
        let t = terminal()
        let url = "https://example.com/path?q=value"
        t.feed(text: url + "." + String(repeating: " ", count: 30))
        let match = try #require(t.linkMatch(at: .screen(Position(col: 3, row: 0)), mode: .explicitAndImplicit))
        #expect(match.text == url)
        #expect(match.range == 0..<url.count)
        #expect(t.link(at: .screen(Position(col: url.count + 1, row: 0)), mode: .explicitAndImplicit) == nil)
    }

    @Test func explicitOSC8LinkKeepsItsLabelRange() throws {
        let t = terminal()
        let url = "file:///tmp/example.txt"
        let label = "a file label"
        t.feed(text: "\u{1b}]8;;" + url + "\u{7}" + label + "\u{1b}]8;;\u{7}" + String(repeating: " ", count: 30))
        let match = try #require(t.linkMatch(at: .screen(Position(col: 2, row: 0)), mode: .explicitAndImplicit))
        #expect(match.text == url)
        #expect(match.isExplicit)
        #expect(match.range == 0..<label.count)
        #expect(t.link(at: .screen(Position(col: label.count, row: 0)), mode: .explicitOnly) == nil)
    }

    @MainActor
    @Test func nativeCmdHoverDecoratesOnlyPathCellsAndClears() throws {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let t = view.getTerminal()
        let prefix = "  chmod 600 "
        let path = ".local/discord-pilot/webhook.url"
        let end = prefix.count + path.count
        view.feed(text: prefix + path + String(repeating: " ", count: t.cols - end))

        func decoratedColumns() -> Set<Int> {
            let info = view.buildAttributedString(row: 0, line: t.displayBuffer.lines[0], cols: t.cols)
            var columns = Set<Int>()
            for segment in info.segments {
                let text = segment.attributedString
                text.enumerateAttribute(.underlineStyle, in: NSRange(location: 0, length: text.length)) { style, range, _ in
                    guard style != nil else { return }
                    for index in range.location..<(range.location + range.length) {
                        columns.insert(segment.column + segment.cellOrdinal(forUTF16: index) * segment.columnWidth)
                    }
                }
            }
            return columns
        }

        let hit = Position(col: prefix.count + 2, row: 0)
        view.updateHoverLink(at: hit)
        #expect(decoratedColumns().isEmpty, "No modifier, no hover underline")

        view.commandActive = true
        view.updateHoverLink(at: hit)
        #expect(decoratedColumns() == Set(prefix.count..<end))

        view.updateHoverLink(at: Position(col: end + 2, row: 0))
        #expect(decoratedColumns().isEmpty, "Hovering padding must clear the underline")

        view.updateHoverLink(at: hit)
        view.turnOffUrlPreview()
        #expect(decoratedColumns().isEmpty, "Releasing Command must clear the underline")
    }
}
