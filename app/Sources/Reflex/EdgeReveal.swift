import AppKit

// The rail stays out of sight. Rest the pointer on the right edge of a screen
// for half a second (a sliver grows there meanwhile) and it slides in at the
// pointer's height. It stays while the pointer is anywhere near it — a
// generous dead zone and a short grace period — then slides away.

@MainActor
final class EdgeReveal {
    /// Seconds of stillness at the edge before the rail appears.
    var delay: TimeInterval = 0.5
    /// How far around the rail the pointer may wander before it hides.
    let deadzone = CGSize(width: 96, height: 64)
    /// How long the pointer may be outside the dead zone before it hides.
    let grace: TimeInterval = 0.5
    /// Pointer jitter tolerated while dwelling (points).
    let tolerance: CGFloat = 6

    var place: (_ screen: NSScreen, _ y: CGFloat) -> Void = { _, _ in }
    var panel: () -> NSWindow? = { nil }
    var keepOpen: () -> Bool = { false }
    var onReveal: () -> Void = {}

    private var timer: Timer?
    private var dwellStart: NSPoint?
    private var dwellAt: TimeInterval = 0
    private var holdUntil: TimeInterval = 0

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private let debugDwell = ProcessInfo.processInfo.environment["REFLEX_DEBUG_DWELL"] != nil

    private func tick() {
        if debugDwell { return }
        let rail = RailModel.shared
        let p = NSEvent.mouseLocation
        if Settings.shared.railAlways {
            if !rail.visible, let s = screen(at: p) ?? NSScreen.main { show(on: s, y: s.visibleFrame.midY) }
            return
        }
        if rail.visible {
            if let f = panel()?.frame, f.insetBy(dx: -deadzone.width, dy: -deadzone.height).contains(p) || rail.expanded || keepOpen() {
                holdUntil = max(holdUntil, now + grace)
            }
            if now > holdUntil { hide() }
            return
        }
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
            place(s, p.y)
        }
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
        rail.visible = false
        rail.expanded = false
        panel()?.ignoresMouseEvents = true
        rail.settle()
    }

    /// A new question: surface the rail briefly at mid-height, like a notification.
    func surface() {
        guard !RailModel.shared.visible, let s = NSScreen.main else { return }
        show(on: s, y: s.visibleFrame.midY, hold: 6)
    }
}
