import SwiftUI

/// Full-panel empty state for the collection screens (Crate / Grid) when the library has no
/// albums at all. Points at the two ways to get music in: connect Bandcamp, or import local files.
struct CollectionEmptyState: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: Space.s5) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(p.muted2)
                .accessibilityHidden(true)

            VStack(spacing: Space.s2) {
                Text(state.isConnected ? "Your collection is empty" : "No music yet")
                    .font(.system(size: 20, weight: .bold)).kerning(-0.3)
                    .foregroundStyle(p.text)
                Text(state.isConnected
                     ? "Sync pulls in your Bandcamp albums, or import files from your Mac."
                     : "Connect your Bandcamp collection, or import files from your Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(p.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            HStack(spacing: Space.s3) {
                if !state.isConnected {
                    Button { state.connect() } label: {
                        Text("Connect Bandcamp").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(p.accentInk)
                            .padding(.vertical, 10).padding(.horizontal, Space.s5)
                            .background(Capsule().fill(p.accent))
                    }.buttonStyle(.soft)
                }
                Button { state.pickAndImport() } label: {
                    Text("Import files…").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text)
                        .padding(.vertical, 10).padding(.horizontal, Space.s5)
                        .background(Capsule().fill(p.glassFill))
                        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                }.buttonStyle(.soft)
            }
            .padding(.top, Space.s2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
