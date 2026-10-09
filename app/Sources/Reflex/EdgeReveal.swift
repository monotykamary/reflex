import AppKit

// When the rail opens, and when it goes.
//
//   tab showing   hover the tab (a short intent) and the rail opens there
//   no tab        rest on the right edge of a screen for half a second — a
//                 sliver grows meanwhile — and the rail opens at that height
//   open          it stays while the pointer is anywhere near it (a generous
//                 dead zone, then a short grace) and closes back into the tab
//
// While the pointer is over the open rail it takes the keyboard (1–3 answer
// the card); when the pointer leaves, focus goes back to the app you were in.

@MainActor
final class EdgeReveal {
    var delay: TimeInterval = 0.5
    let tabIntent: TimeInterval = 0.12
    let deadzone = CGSize(width: 96, height: 64)
    let grace: TimeInterval = 0.5
    let tolerance: CGFloat = 6

    /// Anchor the rail at a height on a screen.
    var place: (_ screen: NSScreen, _ y: CGFloat) -> Void = { _, _ in }
    var panel: () -> NSWindow? = { nil }
    var sliver: () -> NSWindow? = { nil }
    var tabShown: () -> Bool = { false }
    var anchor: () -> (NSScreen, CGFloat)? = { nil }
    var keepOpen: () -> Bool = { false }
    var onReveal: () -> Void = {}

    private var timer: Timer?
    private var dwellStart: NSPoint?
    private var dwellAt: TimeInterval = 0
    private var tabHoverAt: TimeInterval?
    private var holdUntil: TimeInterval = 0
    private var lent: NSRunningApplication?
    private let debugDwell = ProcessInfo.processInfo.environment["REFLEX_DEBUG_DWELL"] != nil

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func fallbackAnchor() -> (NSScreen, CGFloat)? {
        anchor() ?? NSScreen.main.map { ($0, $0.visibleFrame.midY) }
    }

    private func tick() {
        if debugDwell { return }
        let rail = RailModel.shared
        let p = NSEvent.mouseLocation
        if Settings.shared.railAlways {
            if !rail.visible, let (s, y) = fallbackAnchor() { show(on: s, y: y) }
            return
        }
        if rail.visible {
            let frame = panel()?.frame ?? .zero
            let over = frame.contains(p)
            if over || frame.insetBy(dx: -deadzone.width, dy: -deadzone.height).contains(p) || keepOpen() {
                holdUntil = max(holdUntil, now + grace)
            }
            takeKeys(over)
            if now > holdUntil { hide() }
            return
        }
        // Hovering the tab opens the rail where the tab is.
        if tabShown(), let f = panel()?.frame, f.insetBy(dx: -2, dy: -4).contains(p) {
            if let t = tabHoverAt {
                if now - t >= tabIntent, let (s, y) = fallbackAnchor() { show(on: s, y: y) }
            } else {
                tabHoverAt = now
            }
            return
        }
        tabHoverAt = nil
        // An empty edge: dwell, with the sliver growing.
        guard let s = screen(at: p), atRealEdge(p, of: s) else {
            if dwellStart != nil || rail.dwell != 0 { dwellStart = nil; rail.dwell = 0 }
            return
        }
        if let start = dwellStart, hypot(p.x - start.x, p.y - start.y) <= tolerance {
            let progress = min(1, (now - dwellAt) / delay)
            rail.dwell = progress
            if progress >= 1 { show(on: s, y: p.y) }
        } else {
            dwellStart = p
            dwellAt = now
            rail.dwell = 0
            sliver()?.setFrameOrigin(NSPoint(x: s.frame.maxX - 14, y: p.y - 60))
        }
    }

    /// Over the rail: it takes the keys. Off it: the app you were in gets them back.
    private func takeKeys(_ over: Bool) {
        guard let w = panel() else { return }
        if over && !w.isKeyWindow {
            let front = NSWorkspace.shared.frontmostApplication
            lent = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            w.makeKey()
        } else if !over && w.isKeyWindow {
            returnKeys()
        }
    }

    private func returnKeys() {
        guard let w = panel(), w.isKeyWindow else { return }
        if let app = lent { app.activate() } else { w.resignKey() }
        lent = nil
    }

    private func screen(at p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    /// The right edge of this screen, where no other screen continues.
    private func atRealEdge(_ p: NSPoint, of s: NSScreen) -> Bool {
        guard p.x >= s.frame.maxX - 3 else { return false }
        let beyond = NSPoint(x: s.frame.maxX + 4, y: p.y)
        return !NSScreen.screens.contains { $0 !== s && NSMouseInRect(beyond, $0.frame, false) }
    }

    func show(on s: NSScreen, y: CGFloat, hold: TimeInterval = 0) {
        place(s, y)
        dwellStart = nil
        tabHoverAt = nil
        RailModel.shared.dwell = 0
        panel()?.ignoresMouseEvents = false
        holdUntil = now + max(grace, hold)
        if !RailModel.shared.visible {
            RailModel.shared.visible = true
            onReveal()
        }
    }

    func hide() {
        let rail = RailModel.shared
        guard rail.visible else { return }
        returnKeys()
        rail.visible = false
        panel()?.ignoresMouseEvents = !tabShown()
    }

    /// A new question: open the rail where it is anchored, like a notification.
    func surface() {
        guard !RailModel.shared.visible, let (s, y) = fallbackAnchor() else { return }
        show(on: s, y: y, hold: 6)
    }
}
