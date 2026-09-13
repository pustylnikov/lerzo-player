import SwiftUI
import Sparkle

/// Sparkle auto-updates. The feed URL and the EdDSA public key live in Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`, written by build_app.sh); scripts/release.sh
/// signs each DMG and regenerates the appcast next to it.
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController
    /// False while a check is already running or the updater is not ready yet.
    @Published private(set) var canCheckForUpdates = false

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
