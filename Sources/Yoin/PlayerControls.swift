import Foundation

/// Pure helpers shared by every player surface (NowPlaying, PlayerBar, the two mini players,
/// Art mode). These were previously re-typed verbatim in each view — the scroll-wheel nudge math
/// alone was copy-pasted six times — so a tweak to the feel had to be found in 4–5 files. Kept as
/// pure functions so the fiddly bits (the scroll divisor, the mm:ss formatting, the volume-glyph
/// ladder) live once and are unit-testable without mounting any view.
enum PlayerControls {
    /// mm:ss for a transport time; guards NaN/negative to "0:00".
    static func timeString(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The speaker glyph for a 0…1 volume: slash when silent, then 1/2/3 waves.
    static func volumeGlyph(_ volume: Double) -> String {
        if volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// A scroll-wheel nudge, clamped to 0…1: `base + step`, where a coarse (non-`precise`) wheel
    /// tick is amplified ×8 and the whole thing is scaled by `divisor` (larger = gentler).
    static func scrollNudge(base: Double, raw: Double, precise: Bool, divisor: Double) -> Double {
        min(1, max(0, base + (precise ? raw : raw * 8) / divisor))
    }

    /// Gentler for seeking a whole track; a bit stronger for volume.
    static let seekDivisor = 900.0
    static let volumeDivisor = 600.0
}
