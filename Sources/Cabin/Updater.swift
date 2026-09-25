import SwiftUI
#if !APPSTORE
import Sparkle
#endif

/// Wraps Sparkle's updater so SwiftUI can drive "Check for Updates" and keep the
/// menu item enabled only when a check is actually possible.
///
/// The feed URL and EdDSA public key live in the app bundle's Info.plist
/// (SUFeedURL / SUPublicEDKey), written by package.sh. Sparkle verifies every
/// downloaded update against that key, so a compromised feed can't ship a build.
#if !APPSTORE
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
#else
/// Mac App Store build: the App Store delivers updates, so there's nothing to check.
@MainActor
final class UpdaterModel: ObservableObject {
    @Published var canCheckForUpdates = false
    func checkForUpdates() {}
}
#endif
