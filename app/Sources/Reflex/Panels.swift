import AppKit
import SwiftUI

// Borderless, transparent panels that host SwiftUI glass. Panels have fixed
// frames and SwiftUI animates inside them, so content never jumps while the
// window server resizes a window.

final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onResign: (() -> Void)?
    var keyable = true
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    /// ⌘V before the text field sees it: true when the panel took the paste
    /// (images), false to paste as usual.
    var onPaste: (() -> Bool)?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "v",
           onPaste?() == true { return true }
        return super.performKeyEquivalent(with: e)
    }
    /// ⌫ before the text field sees it: true when the panel took it (the bar
    /// removing a token from an empty field). Only a fresh press, never a held
    /// key's repeats: deleting text stops at the empty field.
    var onBackspace: (() -> Bool)?
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, e.keyCode == 51, !e.isARepeat,
           e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           onBackspace?() == true { return }
        super.sendEvent(e)
    }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// Clicks act on the first press, even in a panel that never becomes key
/// (the rail): no click is spent just focusing the window.
final class FirstClickHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum Panels {
    static func floating<V: View>(_ view: V, size: NSSize, key: Bool) -> KeyPanel {
        // Non-activating even when key: like Spotlight, the panel takes keystrokes
        // without activating Reflex or taking focus away from the user's app.
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        p.keyable = key
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        let host = FirstClickHost(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    /// Fit a floating window to its content's measured size, keeping its top
    /// edge and horizontal centre: grow at once, shrink once the old content
    /// has had time to animate away. A window larger than what it shows would
    /// swallow clicks meant for the apps beneath its transparent part.
    @MainActor static func fit(_ w: NSWindow, to size: NSSize, top: CGFloat, midX: CGFloat) {
        // Whole points, and the top edge exactly where it was: rounding the
        // origin and the height separately would let the top hop by a point.
        let width = ceil(size.width), height = ceil(size.height)
        let target = NSRect(x: (midX - width / 2).rounded(), y: top.rounded() - height, width: width, height: height)
        let cur = w.frame
        fitTickets[ObjectIdentifier(w), default: 0] += 1
        let ticket = fitTickets[ObjectIdentifier(w)]
        if !w.isVisible || (target.width >= cur.width && target.height >= cur.height) {
            w.setFrame(target, display: true)
            return
        }
        let grown = NSRect(x: min(cur.minX, target.minX), y: min(cur.minY, target.minY),
                           width: max(cur.maxX, target.maxX) - min(cur.minX, target.minX),
                           height: max(cur.maxY, target.maxY) - min(cur.minY, target.minY))
        if grown != cur { w.setFrame(grown, display: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard fitTickets[ObjectIdentifier(w)] == ticket else { return }
            w.setFrame(target, display: true)
        }
    }

    @MainActor private static var fitTickets: [ObjectIdentifier: Int] = [:]

    static var screen: NSRect { NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    /// Fade a panel out quickly (exits are shorter than entrances), then hide it.
    static func fadeOut(_ w: NSWindow, duration: Double = 0.14, then: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            w.animator().alphaValue = 0
        } completionHandler: {
            w.orderOut(nil)
            w.alphaValue = 1
            then?()
        }
    }
}
