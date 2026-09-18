import SwiftUI

/// "Send to iPhone" — pick which imported albums to put in iCloud for the iPhone app to
/// download. Each album has an on/off toggle: on = uploaded and available on the phone,
/// off = removed from iCloud. Per-row spinner while uploading; feedback via AppState notices.
struct CloudSendView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    private var albums: [Album] { state.sendableAlbums }
    private var unsent: [Album] { albums.filter { !state.cloudUploadedIDs.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Send to iPhone").font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)
                Spacer()
                if !unsent.isEmpty {
                    Button("Send all (\(unsent.count))") { state.cloudSendAll() }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Space.s5)

            Divider().overlay(p.edgeSoft)

            if albums.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 34)).foregroundStyle(p.muted2)
                    Text("No imported songs yet").font(.system(size: 14, weight: .medium)).foregroundStyle(p.muted)
                    Text("Import music from your Mac or Apple Music, then choose it here.")
                        .font(.system(size: 12)).foregroundStyle(p.muted2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(albums) { album in
                            row(album)
                            Divider().overlay(p.edgeSoft)
                        }
                    }
                }
            }

            Divider().overlay(p.edgeSoft)
            Text("Songs you send use your iCloud storage. Once the iPhone downloads a song it's removed from iCloud automatically.")
                .font(.system(size: 11)).foregroundStyle(p.muted2)
                .padding(Space.s4)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 460, idealHeight: 560)
        .background(p.page)
        .onAppear { state.refreshCloudUploadedState() }
    }

    private func row(_ album: Album) -> some View {
        HStack(spacing: 12) {
            cover(album)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                Text(album.artist).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                Text(subtitle(album)).font(.system(size: 11)).foregroundStyle(p.muted2)
            }
            Spacer(minLength: 8)
            if state.cloudUploadingIDs.contains(album.id) {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { state.cloudUploadedIDs.contains(album.id) },
                    set: { on in if on { state.cloudSend(album) } else { state.cloudUnsend(album.id) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(state.cloudUploadedIDs.contains(album.id) ? "On iPhone — turn off to remove from iCloud" : "Send to iPhone")
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
    }

    private func cover(_ album: Album) -> some View {
        Group {
            if let img = album.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(album.cover)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func subtitle(_ album: Album) -> String {
        let n = album.localTracks?.count ?? (album.url != nil ? 1 : 0)
        return "\(n) track\(n == 1 ? "" : "s")"
    }
}
