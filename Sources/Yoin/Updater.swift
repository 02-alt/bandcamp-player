import SwiftUI
import Sparkle

/// Wraps Sparkle's updater so SwiftUI can drive "Check for Updates" and keep the
/// menu item enabled only when a check is actually possible.
///
/// The feed URL and EdDSA public key live in the app bundle's Info.plist
/// (SUFeedURL / SUPublicEDKey), written by package.sh. Sparkle verifies every
/// downloaded update against that key, so a compromised feed can't ship a build.
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater: true — Sparkle begins its scheduled background checks
        // immediately (respecting the user's SUEnableAutomaticChecks choice).
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// User-initiated check — shows Sparkle's UI (progress, release notes, "up to date").
    func checkForUpdates() { controller.checkForUpdates(nil) }
}
