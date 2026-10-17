import AppKit
import Combine
import Sparkle

// Updates, through Sparkle: Reflex checks its appcast once a day (signed
// with an EdDSA key; the public half is SUPublicEDKey in Info.plist) and
// offers new versions; Check for Updates… asks now.
//
// Reflex mostly runs in the background (menu bar only, or behind your
// terminals), where Sparkle would show a scheduled update's window behind
// other apps, unseen. So unless Sparkle can show it in focus, Reflex keeps it
// as a gentle reminder instead: a dot on the menu bar icon and an "Update to
// …" row in the panel and on the rail, which bring the window forward.

@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    /// A version found by a scheduled check and not yet seen ("0.1.34").
    @Published private(set) var pending: String?
    @Published var automaticallyInstalls = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyInstalls }
    }

    /// Only in a bundle that names a feed (a dev build run from `swift build`
    /// has none, and Sparkle would complain).
    private lazy var controller: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }()

    static func start() {
        guard let c = shared.controller else { return }
        shared.automaticallyInstalls = c.updater.automaticallyDownloadsUpdates
    }

    static var available: Bool { shared.controller != nil }

    /// Ask now; with an update already waiting, bring its window forward.
    static func check() {
        NSApp.activate()
        shared.controller?.checkForUpdates(nil)
    }

    /// The menus' item: the waiting version by name, once there is one.
    var menuTitle: String { pending.map { "Update to \($0)…" } ?? "Check for Updates…" }

    /// When Sparkle last asked the appcast.
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows it only when it would be in front; otherwise the reminder does.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in
            if !handleShowingUpdate { Updater.shared.pending = version }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in Updater.shared.pending = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in Updater.shared.pending = nil }
    }
}
