import Foundation

@main struct SizeOwnershipTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }
        var state = CoreSize()
        let now = Date(timeIntervalSince1970: 1_000)
        state.ask(cols: 90, rows: 25, now: now)
        check(state.sized(cols: 90, rows: 25, own: (100, 30), following: false, now: now) == .stay,
              "intermediate local resize acknowledgements do not paint")
        check(state.sized(cols: 100, rows: 30, own: (100, 30), following: false, now: now) == .repaint,
              "a settled local resize requests a read-only repaint")
        state.painted()
        check(state.sized(cols: 100, rows: 30, own: (100, 30), following: false, now: now) == .stay,
              "an unchanged current screen needs no repaint")
        check(state.sized(cols: 100, rows: 30, own: (100, 30), following: true, now: now) == .own,
              "matching geometry unpins the view without claiming control")
        let core = CoreLink.shared
        let a = TerminalSession(cols: 80, rows: 24)
        let b = TerminalSession(cols: 100, rows: 30)
        a.open(); await settle()
        b.open(); await settle()
        check(core.size == (100, 30), "the last opened key window controls the size")
        check(a.sizedElsewhere && a.view.pinned?.cols == 100 && a.view.pinned?.rows == 30, "the other machine follows")
        check(core.activeAttaches == 2, "following never reopens an interactive stream")
        let stable = core.resizes
        await settle()
        check(core.resizes == stable, "two key windows remain stable without user activity")

        let beforeTyping = core.resizes.count
        a.view.type("hello")
        await settle()
        check(core.size == (80, 24) && core.resizes.count == beforeTyping + 1, "typing transfers size exactly once")
        check(core.actions.suffix(3) == ["resize 80x24", "focus", "keys hello"], "size is sent before keys on the same stream")
        check(!a.sizedElsewhere && b.sizedElsewhere, "only the most recently used machine controls")
        check(core.activeAttaches == 2, "own-size repaint is also read-only")
        if CommandLine.arguments.contains("--check-passive-paint") { exit(failures == 0 ? 0 : 1) }

        b.view.onFocus?(true)
        await settle()
        check(core.size == (100, 30) && a.sizedElsewhere, "focus transfers size without reattaching")
        let paints = core.observerAttaches
        for (c, r) in [(104, 31), (108, 33), (110, 35)] { b.view.resize(c, r) }
        await settle()
        check(core.size == (110, 35) && (a.view.pinned?.cols == 110 && a.view.pinned?.rows == 35), "resize burst settles at the latest geometry")
        check(core.observerAttaches == paints + 2, "resize burst paints once per viewer")
        check(core.activeAttaches == 2, "resize acknowledgements cannot steal ownership")

        // An old read-only attach completes after activity on the other Mac.
        core.holdNextObserver = true
        a.view.type("first")
        await settle()
        check(core.held != nil, "a paint attach is suspended")
        b.view.onFocus?(true)
        await settle()
        let late = core.release()
        await settle()
        check(late.closed, "late attach is discarded after a newer size event")
        check(core.size == (110, 35) && (a.view.pinned?.cols == 110 && a.view.pinned?.rows == 35), "late paint cannot reclaim size or revert the grid")

        // A reply arrived, but its first frame has not: supersede it too.
        core.holdNextFrame = true
        a.view.type("second")
        await settle()
        let unpainted = core.unpainted!
        b.view.onFocus?(true)
        await settle()
        unpainted.paint()
        check(unpainted.closed && (a.view.pinned?.cols == 110 && a.view.pinned?.rows == 35), "superseded first frame never reaches the view")

        // Matching dimensions are a display decision, not activity.
        b.view.resize(80, 24)
        await settle()
        check(!a.sizedElsewhere && core.owner?.cols == 80, "matching geometry does not require a new controller")
        check(core.activeAttaches == 2, "matching-size events never attach actively")
        var sizing = CoreSize()
        check(sizing.sized(cols: 200, rows: 120, own: (80, 24), following: true) == .follow(cols: 200, rows: 120),
              "headless-looking geometry is followed, not claimed automatically")

        core.holdNextObserver = true
        b.view.resize(120, 40)
        await settle()
        check(core.held != nil, "a final refresh is pending during close")
        a.stop(); b.stop()
        let closing = core.release()
        await settle()
        check(closing.closed && core.live.isEmpty, "close cancels refreshes and releases every stream")
        print(failures == 0 ? "Size ownership: all checks passed" : "Size ownership: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
