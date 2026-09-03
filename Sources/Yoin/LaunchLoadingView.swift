import SwiftUI

/// Full-window loading screen shown on first launch / empty library while the Bandcamp
/// collection is being fetched. Uses the app's breathing thinking-orb plus a progress bar
/// (determinate when Bandcamp reports a total, otherwise a gentle indeterminate sweep).
struct LaunchLoadingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

    var body: some View {
        ZStack {
            // Opaque page + the same soft blobs as RootView, so it reads as the app "warming up".
            p.page.ignoresSafeArea()
            Circle().fill(p.blob1).frame(width: 520, height: 520).blur(radius: 90)
                .offset(x: -120, y: -320).ignoresSafeArea()
            Circle().fill(p.blob2).frame(width: 460, height: 460).blur(radius: 90)
                .offset(x: 360, y: 340).ignoresSafeArea()

            VStack(spacing: Space.s5) {
                OrbLoader(size: 96)
                VStack(spacing: Space.s2) {
                    Text("Loading your collection")
                        .font(.system(size: 16, weight: .bold)).kerning(-0.2).foregroundStyle(p.text)
                    Text(caption)
                        .font(.system(size: 12)).foregroundStyle(p.muted)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.2), value: state.syncLoaded)
                }
                ProgressBar(fraction: state.syncFraction)
                    .frame(width: 240, height: 6)
            }
        }
        .transition(.opacity)
    }

    private var caption: String {
        if let total = totalOrNil {
            return "\(min(state.syncLoaded, total)) of \(total) albums"
        }
        return state.syncLoaded > 0 ? "\(state.syncLoaded) albums" : "Connecting to Bandcamp…"
    }
    private var totalOrNil: Int? { state.syncTotal > 0 ? state.syncTotal : nil }
}

/// A slim capsule bar: a determinate fill when `fraction` is known, else an indeterminate
/// segment sweeping left→right.
private struct ProgressBar: View {
    let fraction: Double?
    @Environment(\.palette) private var p
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(p.glassFill)
                    .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                if let fraction {
                    Capsule().fill(p.accent)
                        .frame(width: max(6, w * CGFloat(fraction)))
                        .animation(.easeOut(duration: 0.3), value: fraction)
                } else {
                    // Indeterminate: a short segment that slides across and repeats.
                    Capsule().fill(p.accent)
                        .frame(width: w * 0.32)
                        .offset(x: sweep ? w * 0.68 : -w * 0.32)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false), value: sweep)
                        .onAppear { sweep = true }
                }
            }
        }
    }
}
