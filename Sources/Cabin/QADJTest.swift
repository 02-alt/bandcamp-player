#if DEBUG
import AppKit

/// Debug-only, muted engine test for Slowed + Reverb: `CABIN_DJTEST=local|stream` plays a downloaded
/// (or streamed) album silently, flips the effects in and out, drags the speed, logs engine state +
/// position every 100 ms to /tmp/cabin-djtest-<mode>.log, restores the user's DJ settings and quits.
@MainActor
enum QADJTest {
    static func run(mode: String, state: AppState, player: PlayerEngine) {
        PlayerEngine.qaMute = true
        player.trackFinished = nil          // keep the test out of listening history
        player.queueAdvanced = nil
        let saved = (player.djMode, player.speed, player.pitch, player.reverbMix)
        let savedRoom = (player.roomEnabled, player.roomPresetName)
        let album = mode == "local"
            ? state.albums.first { $0.hasLocalFiles && $0.isPlayable }
            : state.albums.first { $0.source == .bandcamp && !$0.hasLocalFiles && $0.isPlayable }
        let rec = Recorder()
        func log(_ s: String) { rec.lines.append(s) }
        guard let album else { log("NO_ALBUM"); finish(); return }
        log("ALBUM \(album.title)")
        player.djMode = false; player.pitch = 0; player.reverbMix = 0
        state.play(album, on: player)

        Task { @MainActor in
            // Wait for playback to really start.
            for _ in 0..<200 where !(player.isPlaying && player.currentTime > 1) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let t0 = Date()
            let startIndex = player.index
            let sampler = Task { @MainActor in
                while !Task.isCancelled {
                    log(String(format: "S %.2f %@ %d %@ %.3f %.2f %d", Date().timeIntervalSince(t0),
                               player.qaEngine, player.index, player.isPlaying ? "play" : "stop",
                               player.currentTime, player.djMode ? player.speed : 1.0, player.qaRatePushes))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            @MainActor func at(_ sec: Double, _ label: String, _ body: @MainActor () -> Void) async {
                let wait = sec - Date().timeIntervalSince(t0)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                log(String(format: "E %.2f %@", Date().timeIntervalSince(t0), label)); body()
            }
            await at(2, "classic") { player.djMode = true; player.speed = 0.80; player.pitch = 0; player.reverbMix = 40 }
            await at(5, "normal") { player.djMode = false; player.pitch = 0; player.reverbMix = 0 }
            await at(8, "classic") { player.djMode = true; player.speed = 0.80; player.pitch = 0; player.reverbMix = 40 }
            await at(11, "drag") {}
            for i in 1...20 { player.speed = 0.80 + 0.2 * Double(i) / 20; try? await Task.sleep(for: .milliseconds(30)) }
            await at(14, "room") { player.roomEnabled = true }
            if let room = Room.presets.first { player.roomPresetName = room.name }
            await at(16, "end") {}
            sampler.cancel()
            log("INDEX start=\(startIndex) end=\(player.index)")
            player.djMode = saved.0; player.speed = saved.1; player.pitch = saved.2; player.reverbMix = saved.3
            player.roomEnabled = savedRoom.0; player.roomPresetName = savedRoom.1
            finish()
        }

        func finish() {
            try? rec.lines.joined(separator: "\n").write(toFile: "/tmp/cabin-djtest-\(mode).log", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

@MainActor private final class Recorder { var lines: [String] = [] }
#endif
