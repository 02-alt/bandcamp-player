import AppKit

/// AppleScript / Apple Events support so other apps (e.g. the NotchGlass media
/// player tab) can read Yoin's now-playing state and drive transport, using the
/// same vocabulary as Music and Spotify:
///
///     tell application "Yoin"
///         player state                       -- playing / paused / stopped
///         name of current track
///         artist of current track
///         album of current track
///         duration of current track          -- seconds
///         player position                    -- seconds (settable → seek)
///         sound volume                       -- 0–100 (settable)
///         artwork url of current track       -- http URL, when available
///         playpause / next track / previous track
///     end tell
///
/// The scripting objects (application = NSApp, plus `track`) resolve their values
/// through this bridge, which holds weak references to the live engine and app
/// state. Apple Events arrive on the main run loop, so the getters/setters read
/// the @MainActor objects via `MainActor.assumeIsolated`.
@MainActor
final class ScriptingBridge {
    static let shared = ScriptingBridge()
    weak var player: PlayerEngine?
    weak var state: AppState?
    private init() {}
}

/// Build a FourCharCode from a 4-character ASCII string (matches the sdef codes).
private func fourCharCode(_ s: StaticString) -> FourCharCode {
    var code: FourCharCode = 0
    s.withUTF8Buffer { buf in
        for byte in buf.prefix(4) { code = (code << 8) + FourCharCode(byte) }
    }
    return code
}

private let kPlayerStatePlaying = fourCharCode("kPSP")
private let kPlayerStatePaused  = fourCharCode("kPSp")
private let kPlayerStateStopped = fourCharCode("kPSS")

// MARK: - Application scripting properties (the `application` class → NSApp)

extension NSApplication {
    /// `player state` — an enumerator whose raw value is the sdef enumerator code.
    @objc var playerState: NSNumber {
        MainActor.assumeIsolated {
            guard let player = ScriptingBridge.shared.player, player.current != nil else {
                return NSNumber(value: kPlayerStateStopped)
            }
            return NSNumber(value: player.isPlaying ? kPlayerStatePlaying : kPlayerStatePaused)
        }
    }

    /// `player position` — the playhead, in seconds. Settable to seek.
    @objc var playerPosition: Double {
        get { MainActor.assumeIsolated { ScriptingBridge.shared.player?.currentTime ?? 0 } }
        set {
            MainActor.assumeIsolated {
                guard let player = ScriptingBridge.shared.player, player.duration > 0 else { return }
                player.seek(fraction: newValue / player.duration)
            }
        }
    }

    /// `sound volume` — output volume on a 0–100 scale (Yoin stores it as 0…1).
    @objc var soundVolume: Int {
        get { MainActor.assumeIsolated { Int((( ScriptingBridge.shared.player?.volume ?? 0) * 100).rounded()) } }
        set {
            MainActor.assumeIsolated {
                ScriptingBridge.shared.player?.volume = max(0, min(1, Double(newValue) / 100))
            }
        }
    }

    /// `current track` — the loaded track, or nil when nothing is queued.
    @objc var currentTrack: YoinTrack? {
        MainActor.assumeIsolated {
            guard let player = ScriptingBridge.shared.player, let track = player.current else { return nil }
            return YoinTrack(title: track.title,
                             artist: track.artist,
                             album: ScriptingBridge.shared.state?.nowPlayingAlbum?.title ?? "",
                             duration: player.duration,
                             artworkURL: track.artworkURL?.absoluteString ?? "")
        }
    }
}

// MARK: - The `track` scripting class

/// A snapshot of the current track, exposed to AppleScript. A plain value object —
/// its properties are read once per access, so no object specifier is needed (the
/// script only ever reads sub-properties like `name of current track`).
@objc(YoinTrack)
final class YoinTrack: NSObject, @unchecked Sendable {   // immutable lets → safe to share
    @objc let name: String
    @objc let artist: String
    @objc let album: String
    @objc let duration: Double
    @objc let artworkUrl: String

    init(title: String, artist: String, album: String, duration: Double, artworkURL: String) {
        self.name = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkUrl = artworkURL
        super.init()
    }
}

// MARK: - Transport commands

@objc(YoinPlayPauseCommand)
final class YoinPlayPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { ScriptingBridge.shared.player?.toggle() }
        return nil
    }
}

@objc(YoinNextCommand)
final class YoinNextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { ScriptingBridge.shared.player?.next() }
        return nil
    }
}

@objc(YoinPreviousCommand)
final class YoinPreviousCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { ScriptingBridge.shared.player?.prev() }
        return nil
    }
}
