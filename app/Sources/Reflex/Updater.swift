import Sparkle

// Updates, through Sparkle: Reflex checks its appcast once a day (signed
// with an EdDSA key; the public half is SUPublicEDKey in Info.plist) and
// offers new versions; Check for Updates… asks now.

@MainActor
enum Updater {
    /// Only in a bundle that names a feed (a dev build run from `swift build`
    /// has none, and Sparkle would complain).
    private static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    static func start() { _ = controller }

    static var available: Bool { controller != nil }

    static func check() { controller?.checkForUpdates(nil) }
}
