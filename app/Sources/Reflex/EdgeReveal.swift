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
//
// A screen showing a full-screen app (native full screen, or a window that
// covers the whole screen, menu bar too: Parsec, a game, a video) is left
// alone: no tab, no edge to hover, no rail.

@MainActor
final class EdgeReveal {
    var delay: TimeInterval { Settings.shared.edgeDelay }
    let tabIntent: TimeInterval = 0.12
    /// How far outside the rail the pointer may stray before it starts closing.
    let deadzone = CGSize(width: 40, height: 32)

    /// Whether a point is on the open rail or within its dead zone.
    func near(_ p: NSPoint) -> Bool {
        rects().contains { $0.insetBy(dx: -deadzone.width, dy: -deadzone.height).contains(p) }
    }
    let grace: TimeInterval = 0.5
    let tolerance: CGFloat = 6

    /// Anchor the rail at a height on a screen.
    var place: (_ screen: NSScreen, _ y: CGFloat) -> Void = { _, _ in }
    var panel: () -> NSWindow? = { nil }
    /// The window beside the column (question card, agent list).
    var side: () -> NSWindow? = { nil }
    /// Where the open rail's content is on screen — the column, and what sits
    /// beside it when that takes clicks. (Its windows are larger, and clear.)
    var rects: () -> [NSRect] = { [] }
    /// Where the edge tab is on screen.
    var tabRect: () -> NSRect? = { nil }
    /// The invisible window that takes the keys while the pointer is on the rail.
    var keys: () -> NSWindow? = { nil }
    var sliver: () -> NSWindow? = { nil }
    var tabShown: () -> Bool = { false }
    var anchor: () -> (NSScreen, CGFloat)? = { nil }
    var keepOpen: () -> Bool = { false }
    /// Another Reflex panel (the bar, the inbox) has the keys: leave them there.
    var othersKey: () -> Bool = { false }
    var onReveal: () -> Void = {}
    /// Off while the rail lives in the menu bar.
    var enabled: () -> Bool = { true }
    /// The edge's windows (tab, sliver, column, side): hidden on a screen a
    /// full-screen app has.
    var windows: () -> [NSWindow] = { [] }

    /// Screens a full-screen app covers, looked at twice a second.
    private var covered: [NSScreen] = []
    private var coveredAt: TimeInterval = 0

    private var timer: Timer?
    private var dwellStart: NSPoint?
    private var dwellAt: TimeInterval = 0
    private var tabHoverAt: TimeInterval?
    private var holdUntil: TimeInterval = 0
    private var lent: NSRunningApplication?
    /// Where the pointer was when the rail opened. Until it moves, the rail
    /// does not take the keyboard: a rail that slid out under a resting
    /// pointer (a question arriving) must not swallow what you type elsewhere.
    private var shownAt: NSPoint?
    private let debugDwell = ProcessInfo.processInfo.environment["REFLEX_DEBUG_DWELL"] != nil
    private let debugHover = ProcessInfo.processInfo.environment["REFLEX_DEBUG_HOVER"] != nil

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func fallbackAnchor() -> (NSScreen, CGFloat)? {
        anchor() ?? NSScreen.main.map { ($0, $0.visibleFrame.midY) }
    }

    private func tick() {
        if debugDwell { return }
        let rail = RailModel.shared
        guard enabled() else {
            if rail.visible { hide() }
            if dwellStart != nil || rail.dwell != 0 { dwellStart = nil; rail.dwell = 0 }
            return
        }
        let p = NSEvent.mouseLocation
        if now - coveredAt > 0.5 {
            coveredAt = now
            covered = FullScreen.covered()
            for w in windows() {
                let hidden = covered.contains { $0.frame.intersects(w.frame) }
                if (w.alphaValue == 0) != hidden { w.alphaValue = hidden ? 0 : 1 }
            }
        }
        if let s = screen(at: p), covered.contains(where: { $0 === s }) {
            if rail.visible, !keepOpen() { hide() }
            if dwellStart != nil || rail.dwell != 0 { dwellStart = nil; rail.dwell = 0 }
            tabHoverAt = nil
            return
        }
        if Settings.shared.railAlways {
            if !rail.visible, let (s, y) = fallbackAnchor() { show(on: s, y: y) }
            return
        }
        if rail.visible {
            let under = rects().contains { $0.contains(p) }
            if under || near(p) || keepOpen() {
                holdUntil = max(holdUntil, now + grace)
            }
            let hovering = under || debugHover
            if rail.hovering != hovering { rail.hovering = hovering }
            takeKeys(under)
            if now > holdUntil { hide() }
            return
        }
        // The bar or inbox is up: the edge stays quiet.
        if othersKey() {
            if dwellStart != nil || rail.dwell != 0 { dwellStart = nil; rail.dwell = 0 }
            tabHoverAt = nil
            return
        }
        // Hovering the tab opens the rail where the tab is.
        if tabShown(), let f = tabRect(), f.insetBy(dx: -2, dy: -4).contains(p) {
            if let t = tabHoverAt {
                if now - t >= tabIntent, let s = screen(at: p) ?? NSScreen.main { show(on: s, y: f.midY) }
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

    /// Over the rail: the window under the pointer takes the keys. Off it:
    /// the app you were in gets them back.
    private func takeKeys(_ under: Bool) {
        if othersKey() { lent = nil; return }
        if let p0 = shownAt {
            let p = NSEvent.mouseLocation
            if hypot(p.x - p0.x, p.y - p0.y) < 4 { return }
            shownAt = nil
        }
        if under {
            guard !ours.contains(where: \.isKeyWindow) else { return }
            let front = NSWorkspace.shared.frontmostApplication
            lent = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            keys()?.makeKey()
        } else if ours.contains(where: \.isKeyWindow) {
            returnKeys()
        }
    }

    private var ours: [NSWindow] { [panel(), side(), keys()].compactMap { $0 } }

    private func returnKeys() {
        guard let w = ours.first(where: \.isKeyWindow) else { return }
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
        holdUntil = now + max(grace, hold)
        if !RailModel.shared.visible { shownAt = NSEvent.mouseLocation }
        if !RailModel.shared.visible {
            RailModel.shared.visible = true
            onReveal()
        }
    }

    /// Close the rail. Pass `returnFocus: false` when another Reflex panel is
    /// about to take the keys, so the app the rail borrowed them from does not
    /// snatch them back.
    func hide(returnFocus: Bool = true) {
        let rail = RailModel.shared
        guard rail.visible else { return }
        if returnFocus { returnKeys() } else { lent = nil }
        rail.hovering = false
        rail.visible = false
    }

    /// A new question: open the rail where it is anchored, like a notification.
    func surface() {
        guard enabled(), !RailModel.shared.visible, let (s, y) = fallbackAnchor(), !covered.contains(where: { $0 === s }) else { return }
        show(on: s, y: y, hold: 6)
    }
}

/// Which screens a full-screen app has: the frontmost app's window says it's
/// full screen (Accessibility: on a notched MacBook a native full-screen
/// window stops below the notch, the same shape as a zoomed one), or one of
/// another app's ordinary windows covers the whole screen, menu bar included
/// (borderless ones, a game's). Window bounds need no screen-recording
/// permission.
enum FullScreen {
    static func covered() -> [NSScreen] {
        var screens = bounds()
        if let s = frontmost(), !screens.contains(where: { $0 === s }) { screens.append(s) }
        return screens
    }

    /// The screen of the frontmost app's focused window, when it's full screen.
    private static func frontmost() -> NSScreen? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // (An app that's hung mustn't hang the edge.)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let window = w as! AXUIElement
        var full: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &full) == .success, (full as? Bool) == true else { return nil }
        var pos: CFTypeRef?
        var p = CGPoint.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success, let v = pos, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgPoint, &p)
        }
        // (Accessibility measures from the top of the primary screen.)
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x: p.x + 1, y: primary - p.y - 1)
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private static func bounds() -> [NSScreen] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let rects: [CGRect] = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }
        return NSScreen.screens.filter { s in
            // (CoreGraphics measures from the top of the primary screen.)
            let f = CGRect(x: s.frame.minX, y: primary - s.frame.maxY, width: s.frame.width, height: s.frame.height)
            return rects.contains { $0.minX <= f.minX + 1 && $0.minY <= f.minY + 1 && $0.maxX >= f.maxX - 1 && $0.maxY >= f.maxY - 1 }
        }
    }
}
