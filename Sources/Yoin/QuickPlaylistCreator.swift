import SwiftUI

/// A small, centred "name your playlist" prompt shown when you pick **New playlist…** from a
/// right-click menu. It creates the playlist and adds the song/album in one step, in place —
/// no jumping to the Playlists screen. Driven by `AppState.playlistDraft`; ⏎ creates, ⎋ cancels.
struct QuickPlaylistCreator: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    let draft: PlaylistDraft

    @FocusState private var focused: Bool
    @State private var name = ""
    // The click that chose "New playlist…" is still being delivered as this overlay mounts; ignore
    // click-out until we've armed a beat later, or that same click dismisses us instantly.
    @State private var armed = false

    var body: some View {
        ZStack {
            // Dim + click-out to cancel.
            Rectangle().fill(.black.opacity(0.35)).ignoresSafeArea()
                .onTapGesture { if armed { state.cancelPlaylistDraft() } }

            VStack(alignment: .leading, spacing: Space.s4) {
                HStack(spacing: Space.s3) {
                    Image(systemName: "music.note.list").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.accent)
                    Text("New Playlist").font(.system(size: 16, weight: .semibold)).foregroundStyle(p.text)
                }

                TextField("Playlist name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(p.text)
                    .focused($focused)
                    .padding(.vertical, Space.s3).padding(.horizontal, Space.s4)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.glassFill))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
                    .onSubmit(create)

                // What's being added.
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 11)).foregroundStyle(p.muted2)
                    Text("Adding “\(draft.suggestedName)” · \(draft.subtitle)")
                        .font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                }

                HStack(spacing: Space.s3) {
                    Spacer()
                    Button("Cancel") { state.cancelPlaylistDraft() }
                        .buttonStyle(.soft)
                        .keyboardShortcut(.cancelAction)
                    Button("Create", action: create)
                        .buttonStyle(.soft)
                        .foregroundStyle(p.accent)
                }
            }
            .padding(Space.s5)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        }
        .onAppear {
            name = draft.suggestedName
            // Focus + select-all feel: a beat later so the field is mounted.
            DispatchQueue.main.async { focused = true }
            // Arm click-out dismissal after the opening click has fully drained.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { armed = true }
        }
        .onExitCommand { state.cancelPlaylistDraft() }
    }

    private func create() {
        // Ignore any commit before the overlay has settled — a Return/default-action event left
        // over from opening the menu was auto-creating an empty-named playlist on appear.
        guard armed else { return }
        state.commitPlaylistDraft(name: name)
    }
}
