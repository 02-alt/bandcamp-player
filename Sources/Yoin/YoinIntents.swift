import AppIntents

/// Shortcuts / Siri actions. They drive the live engine through `ScriptingBridge.shared`
/// (the same bridge AppleScript uses), so no extra wiring is needed.
@available(macOS 13.0, *)
struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Toggle playback in Yoin.")
    @MainActor func perform() async throws -> some IntentResult {
        ScriptingBridge.shared.player?.toggle()
        return .result()
    }
}

@available(macOS 13.0, *)
struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Track"
    @MainActor func perform() async throws -> some IntentResult {
        ScriptingBridge.shared.player?.next()
        return .result()
    }
}

@available(macOS 13.0, *)
struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Track"
    @MainActor func perform() async throws -> some IntentResult {
        ScriptingBridge.shared.player?.prev()
        return .result()
    }
}

@available(macOS 13.0, *)
struct StartRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Radio"
    static let description = IntentDescription("Start an endless radio station from the current album.")
    @MainActor func perform() async throws -> some IntentResult {
        guard let state = ScriptingBridge.shared.state, let player = ScriptingBridge.shared.player else {
            return .result()
        }
        state.startRadio(album: state.nowPlayingAlbum ?? state.current, on: player)
        return .result()
    }
}

@available(macOS 13.0, *)
struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    static let description = IntentDescription("Return the track playing in Yoin.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let track = ScriptingBridge.shared.player?.current
        let text = track.map { "\($0.title) — \($0.artist)" } ?? "Nothing is playing"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

@available(macOS 13.0, *)
struct YoinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPauseIntent(),
                    phrases: ["Play or pause \(.applicationName)", "\(.applicationName) play pause"],
                    shortTitle: "Play/Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: NextTrackIntent(),
                    phrases: ["Next track in \(.applicationName)", "Skip in \(.applicationName)"],
                    shortTitle: "Next Track", systemImageName: "forward.fill")
        AppShortcut(intent: PreviousTrackIntent(),
                    phrases: ["Previous track in \(.applicationName)"],
                    shortTitle: "Previous Track", systemImageName: "backward.fill")
        AppShortcut(intent: StartRadioIntent(),
                    phrases: ["Start radio in \(.applicationName)"],
                    shortTitle: "Start Radio", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: WhatsPlayingIntent(),
                    phrases: ["What's playing in \(.applicationName)"],
                    shortTitle: "What's Playing", systemImageName: "music.note")
    }
}
