import SwiftUI

/// Scrolling time-synced lyrics, shown in place of the hero disc on Now Playing. The line for the
/// current playback position is bolded and kept centred; tapping any line seeks to it. Driven by
/// `PlaybackClock.time`, so it re-highlights at the clock's tick rate without touching the disc.
struct LyricsPanel: View {
    let lyrics: SyncedLyrics
    /// Seek to a timestamp (seconds) when a line is tapped.
    let onSeek: (Double) -> Void

    @EnvironmentObject var clock: PlaybackClock
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = lyrics.activeIndex(at: clock.time)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "• • •" : line.text)
                            .font(.system(size: 30, weight: .bold))
                            .kerning(-0.4)
                            .foregroundStyle(p.text)
                            // Tidal look: one cream colour throughout, the current line full-bright,
                            // everything else softly dimmed.
                            .opacity(i == active ? 1 : 0.42)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onSeek(line.time) }
                            .id(i)
                    }
                }
                // Pad top/bottom by half the viewport so the first and last lines can still
                // settle at the vertical centre when highlighted.
                .padding(.vertical, 120)
                .padding(.horizontal, 4)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: active)
            }
            .onChange(of: active) { _, new in
                guard let new else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .onAppear {
                if let a = active { proxy.scrollTo(a, anchor: .center) }
            }
        }
        // Fade the lyrics out toward the top and bottom edges so scrolling reads softly.
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.14),
                .init(color: .black, location: 0.86),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .accessibilityLabel("Lyrics")
    }
}
