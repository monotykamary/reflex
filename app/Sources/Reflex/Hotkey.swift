import AppKit
import ApplicationServices

// Double-tap Option, with nothing else pressed in between, opens the command
// bar. Watching keys outside the app needs the Accessibility permission.

@MainActor
final class DoubleOption {
    private var lastTap: TimeInterval = 0
    private var optionDown = false
    private var dirty = false
    private var monitors: [Any] = []
    private let window: TimeInterval = 0.35
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flags(e) }
        let key: (NSEvent) -> Void = { [weak self] _ in self?.dirty = true; self?.lastTap = 0 }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in flags(e); return e } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in key(e); return e } as Any)
    }

    private func flags(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let onlyOption = mods == .option
        if onlyOption && !optionDown {
            optionDown = true
            dirty = false
        } else if mods.isEmpty && optionDown {
            optionDown = false
            guard !dirty else { lastTap = 0; return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTap < window {
                lastTap = 0
                action()
            } else {
                lastTap = now
            }
        } else if !mods.isEmpty && !onlyOption {
            dirty = true
            lastTap = 0
        }
    }
}
