import SwiftUI

/// Full-panel state for the collection screens when the library is empty. A brand-new user (not
/// connected) gets a warm welcome; a connected user with an empty library gets a lighter nudge.
struct CollectionEmptyState: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @State private var appear = false

    var body: some View {
        Group {
            if state.isConnected { emptyLibrary } else { welcome }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { appear = true } }
        .accessibilityElement(children: .contain)
    }

    // MARK: First run — a welcome, not an error

    private var welcome: some View {
        VStack(spacing: Space.s6) {
            fannedCovers

            VStack(spacing: Space.s3) {
                Text("Welcome to Cabin")
                    .font(.system(size: 26, weight: .bold)).kerning(-0.5)
                    .foregroundStyle(p.text)
                Text("Your Bandcamp collection, as a record crate you can actually flip through. Connect your account to pull it all in — or drop in music you already have.")
                    .font(.system(size: 14))
                    .foregroundStyle(p.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: Space.s3) {
                connectButton
                importButton
            }
            .padding(.top, Space.s2)

            Text("Private by design — your library stays on your Mac.")
                .font(.system(size: 11)).foregroundStyle(p.muted2)
        }
        .padding(Space.s7)
        .opacity(appear ? 1 : 0)
    }

    // MARK: Connected but empty — a lighter nudge

    private var emptyLibrary: some View {
        VStack(spacing: Space.s5) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(p.muted2)
                .accessibilityHidden(true)
            VStack(spacing: Space.s2) {
                Text("Your crate is waiting")
                    .font(.system(size: 20, weight: .bold)).kerning(-0.3).foregroundStyle(p.text)
                Text("Sync pulls in your Bandcamp albums, or import files from your Mac.")
                    .font(.system(size: 13)).foregroundStyle(p.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            HStack(spacing: Space.s3) {
                Button { Task { await state.syncBandcamp(announce: true) } } label: {
                    Text("Sync now").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(p.accentInk)
                        .padding(.vertical, 10).padding(.horizontal, Space.s5)
                        .background(Capsule().fill(p.accent))
                }.buttonStyle(.soft)
                importButton
            }
            .padding(.top, Space.s2)
        }
    }

    // MARK: Pieces

    private var connectButton: some View {
        Button { state.connect() } label: {
            Text("Connect Bandcamp").font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.accentInk)
                .padding(.vertical, 12).padding(.horizontal, Space.s6)
                .background(Capsule().fill(p.accent))
        }.buttonStyle(.soft)
    }

    private var importButton: some View {
        Button { state.pickAndImport() } label: {
            Text("Import files…").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(p.text)
                .padding(.vertical, 12).padding(.horizontal, Space.s5)
                .background(Capsule().fill(p.glassFill))
                .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
        }.buttonStyle(.soft)
    }

    /// A decorative fan of placeholder covers — hints at the crate and keeps the screen inviting.
    private var fannedCovers: some View {
        let grads: [[Color]] = [
            [Color(red: 0.36, green: 0.55, blue: 0.92), Color(red: 0.16, green: 0.20, blue: 0.42)],
            [Color(red: 0.93, green: 0.42, blue: 0.28), Color(red: 0.42, green: 0.12, blue: 0.10)],
            [Color(red: 0.30, green: 0.72, blue: 0.52), Color(red: 0.10, green: 0.30, blue: 0.24)],
            [Color(red: 0.80, green: 0.65, blue: 0.30), Color(red: 0.32, green: 0.22, blue: 0.06)],
            [Color(red: 0.60, green: 0.40, blue: 0.85), Color(red: 0.20, green: 0.10, blue: 0.36)],
        ]
        return ZStack {
            ForEach(Array(grads.enumerated()), id: \.offset) { i, g in
                let idx = i - grads.count / 2
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: g, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.10)))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                    .rotationEffect(.degrees(Double(idx) * 7))
                    .offset(x: CGFloat(idx) * 30, y: abs(CGFloat(idx)) * 7)
                    .zIndex(Double(-abs(idx)))
            }
        }
        .frame(height: 140)
        .scaleEffect(appear ? 1 : 0.9)
        .opacity(appear ? 1 : 0)
        .accessibilityHidden(true)
    }
}
