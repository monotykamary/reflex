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
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
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
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

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
