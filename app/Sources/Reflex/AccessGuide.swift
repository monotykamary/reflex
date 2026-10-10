import AppKit
import SwiftUI

// Granting Accessibility the way modern Mac apps do it: open System Settings
// at Privacy & Security → Accessibility, and float a small glass card beside
// its window holding Reflex's icon, to drag into the list. The card watches
// for the grant, says so, and gets out of the way.

@MainActor
final class AccessGuide: ObservableObject {
    static let shared = AccessGuide()

    @Published var granted = false
    /// Called once access arrives (restart the ⌥⌥ listener, refresh checks).
    var onGranted: () -> Void = {}
    private var panel: KeyPanel?
    private var timer: Timer?

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// `preview`: show the card only (dev), without System Settings.
    func start(preview: Bool = false) {
        guard preview || !DoubleOption.trusted else { onGranted(); return }
        granted = false
        if !preview { NSWorkspace.shared.open(AccessGuide.settingsURL) }
        if panel == nil {
            let p = Panels.floating(AccessCard(model: self, close: { [weak self] in self?.stop() }),
                                    size: NSSize(width: 360, height: 150), key: false)
            p.level = .statusBar
            p.hasShadow = false
            panel = p
        }
        panel?.alphaValue = 0
        place()
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel?.animator().alphaValue = 1
        }
        timer?.invalidate()
        if preview { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let p = panel, p.isVisible { Panels.fadeOut(p) }
    }

    private func tick() {
        if DoubleOption.trusted && !granted {
            withAnimation(Motion.arrive) { granted = true }
            onGranted()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.stop() }
            return
        }
        if !granted { place() }
    }

    /// Just below System Settings' window, centred on it; inside its lower
    /// edge when there is no room below; bottom centre of the screen when
    /// System Settings is not on screen yet.
    private func place() {
        guard let p = panel else { return }
        let size = p.frame.size
        if let w = AccessGuide.settingsWindow() {
            let screen = NSScreen.screens.first { $0.frame.intersects(w) } ?? NSScreen.main
            let floor = screen?.visibleFrame.minY ?? 0
            var y = w.minY - size.height + 8
            if y < floor { y = w.minY + 12 }
            p.setFrameOrigin(NSPoint(x: w.midX - size.width / 2, y: y))
        } else if let s = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: s.midX - size.width / 2, y: s.minY + 80))
        }
    }

    /// System Settings' main window, in Cocoa screen coordinates.
    static func settingsWindow() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"], width > 200 else { continue }
            return NSRect(x: x, y: primary - y - height, width: width, height: height)
        }
        return nil
    }
}

// MARK: - The card

private struct AccessCard: View {
    @ObservedObject var model: AccessGuide
    var close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var bob = false

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                if model.granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Tone.done)
                        .transition(.symbolEffect(.drawOn))
                } else {
                    DragIcon()
                        .frame(width: 56, height: 56)
                        .help("Drag into the list")
                }
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 4) {
                if model.granted {
                    Text("Reflex can hear ⌥⌥ now").font(.system(size: 14, weight: .semibold))
                    Text("You can close System Settings.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text("Drag Reflex into the list").font(.system(size: 14, weight: .semibold))
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Tone.working)
                            .offset(y: bob ? -3 : 1)
                    }
                    Text("Then make sure its switch is on. Reflex notices by itself.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.blurSwap)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16).padding(.trailing, 28).padding(.vertical, 14)
        .frame(width: 340)
        .raySurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !model.granted {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .help("Close")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.enter, value: model.granted)
        .task {
            guard !reduce else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bob = true }
        }
    }
}

/// Reflex's icon as a real drag source: it carries the app bundle's file
/// URL, which is what System Settings' Accessibility list accepts.
private struct DragIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> DragIconView { DragIconView() }
    func updateNSView(_ view: DragIconView, context: Context) {}
}

final class DragIconView: NSView, NSDraggingSource {
    private let icon = NSApp.applicationIconImage ?? NSImage()

    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 56) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) { NSCursor.closedHand.set() }
    override func mouseUp(with event: NSEvent) { NSCursor.openHand.set() }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}
