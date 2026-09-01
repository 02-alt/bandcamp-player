import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Per-album "Music credits" — label / year / genre and the Tidal-style personnel list.
/// Reads the *live* album from state so it updates as enrichment lands.
struct AlbumCreditsView: View {
    let albumID: UUID
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @State private var loading = false
    @State private var matchShown = false
    @State private var editShown = false

    private var album: Album? { state.albums.first { $0.id == albumID } }

    var body: some View {
        if let album {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack {
                    Text("CREDITS").font(.system(size: 11, weight: .bold)).kerning(1)
                        .foregroundStyle(p.muted2)
                    Spacer()
                    if album.canResetToOriginal {
                        pillButton("arrow.uturn.backward", "Reset to original") {
                            state.resetToOriginal(albumID: albumID)
                        }
                    }
                    pillButton("pencil", "Edit") { editShown = true }
                    pillButton("magnifyingglass", "Wrong album?") { matchShown = true }
                }

                // Label · Year · Genre
                let meta = [album.label, album.year.isEmpty ? nil : album.year, album.genre]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if !meta.isEmpty {
                    Text(meta.joined(separator: "  ·  "))
                        .font(.system(size: 13)).foregroundStyle(p.muted)
                }

                if let credits = album.credits, !credits.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(credits) { c in
                            HStack(alignment: .top, spacing: Space.s4) {
                                Text(c.role).font(.system(size: 13)).foregroundStyle(p.muted2)
                                    .frame(width: 130, alignment: .leading)
                                Text(c.name).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(p.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 6)
                            Divider().overlay(p.edgeSoft)
                        }
                    }
                } else {
                    // No credits yet — offer to fetch, and nudge toward a token for depth.
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Button {
                            Task { loading = true; await state.enrich(albumID: albumID, force: true); loading = false }
                        } label: {
                            HStack(spacing: 6) {
                                if loading { OrbLoader(size: 64) }
                                else { Image(systemName: "sparkles").font(.system(size: 12)) }
                                Text(loading ? "Looking up…" : "Fetch credits").font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(p.accentInk)
                            .padding(.vertical, 9).padding(.horizontal, Space.s4)
                            .background(Capsule().fill(p.accent))
                        }
                        .buttonStyle(.soft).disabled(loading)

                        if MetadataPrefs.creditsSource == .discogs && MetadataPrefs.discogsToken == nil {
                            Text("Discogs needs a token — or switch Credits source to MusicBrainz (no account) in Settings.")
                                .font(.system(size: 11)).foregroundStyle(p.muted2)
                        }
                    }
                }

                if !album.history.isEmpty {
                    historySection(album.history)
                }
            }
            .sheet(isPresented: $matchShown) {
                AlbumMatchSheet(albumID: albumID,
                                initialQuery: initialQuery(for: album))
                    .environment(\.palette, p)
                    .environmentObject(state)
            }
            .sheet(isPresented: $editShown) {
                EditDetailsSheet(albumID: albumID)
                    .environment(\.palette, p)
                    .environmentObject(state)
            }
        }
    }

    /// Reversible edit log — pick any entry to restore the album to that state.
    private func historySection(_ history: [AlbumEdit]) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Divider().overlay(p.edgeSoft).padding(.vertical, Space.s2)
            Text("HISTORY").font(.system(size: 11, weight: .bold)).kerning(1)
                .foregroundStyle(p.muted2)
            Text("Restore an earlier version if a match or edit went wrong.")
                .font(.system(size: 11)).foregroundStyle(p.muted2)
            VStack(spacing: 0) {
                ForEach(history) { edit in
                    HStack(alignment: .top, spacing: Space.s3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(edit.summary).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(p.text).lineLimit(1)
                            Text("was: \(edit.snapshot.title) — \(edit.snapshot.artist)")
                                .font(.system(size: 11)).foregroundStyle(p.muted2).lineLimit(1)
                        }
                        Spacer()
                        Button { state.revert(albumID: albumID, to: edit.id) } label: {
                            Text("Revert").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(p.text)
                                .padding(.vertical, 5).padding(.horizontal, Space.s3)
                                .background(Capsule().fill(p.glassFill))
                                .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                        }.buttonStyle(.soft)
                    }
                    .padding(.vertical, 7)
                    Divider().overlay(p.edgeSoft)
                }
            }
        }
    }

    private func pillButton(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(p.muted)
            .padding(.vertical, 6).padding(.horizontal, Space.s3)
            .background(Capsule().fill(p.glassFill))
            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
        }
        .buttonStyle(.soft)
    }

    private func initialQuery(for album: Album) -> String {
        let seed = state.seedQuery(for: album)
        return [seed.artist, seed.title].compactMap { $0 }.joined(separator: " ")
    }
}

/// Hand-edit an album's core metadata — a manual fallback when no online match fits.
struct EditDetailsSheet: View {
    let albumID: UUID
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var artist = ""
    @State private var year = ""
    @State private var label = ""
    @State private var genre = ""
    @State private var coverURL = ""
    @State private var pickedImageData: Data?
    @State private var loaded = false

    private var album: Album? { state.albums.first { $0.id == albumID } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit details").font(.system(size: 15, weight: .bold))
                    Text("Type the correct info by hand. Credits are kept as-is.")
                        .font(.system(size: 12)).foregroundStyle(p.muted)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.soft).foregroundStyle(p.muted)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    field("Title", text: $title)
                    field("Artist", text: $artist)
                    field("Year", text: $year)
                    field("Label", text: $label)
                    field("Genre", text: $genre)
                    field("Cover image URL", text: $coverURL)
                    HStack(spacing: Space.s3) {
                        Button { pickImage() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo").font(.system(size: 11, weight: .semibold))
                                Text("Choose image file…").font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(p.text)
                            .padding(.vertical, 7).padding(.horizontal, Space.s3)
                            .background(Capsule().fill(p.glassFill))
                            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                        }.buttonStyle(.soft)
                        if pickedImageData != nil {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(p.text)
                                Text("New image selected").font(.system(size: 11)).foregroundStyle(p.muted)
                            }
                        }
                    }
                    Text("Paste an image URL or choose a file to replace the cover. Otherwise it stays as-is.")
                        .font(.system(size: 11)).foregroundStyle(p.muted2)
                }
            }.scrollIndicators(.hidden)

            Button { save() } label: {
                Text("Save changes").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(p.accentInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(p.accent))
            }
            .buttonStyle(.soft)
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(Space.s5)
        .frame(width: 440, height: 520)
        .background(p.page)
        .onAppear(perform: prime)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.8)
                .foregroundStyle(p.muted2)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.vertical, 9).padding(.horizontal, Space.s3)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.glassFill))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
        }
    }

    /// Populate the fields from the album once (guarded so edits aren't overwritten).
    private func prime() {
        guard !loaded, let a = album else { return }
        title = a.title; artist = a.artist; year = a.year
        label = a.label ?? ""; genre = a.genre ?? ""
        coverURL = a.artworkURL?.absoluteString ?? ""
        loaded = true
    }

    private func save() {
        guard var meta = album?.metadata else { return }
        meta.title = title.trimmingCharacters(in: .whitespaces)
        meta.artist = artist.trimmingCharacters(in: .whitespaces)
        meta.year = year.trimmingCharacters(in: .whitespaces)
        meta.label = label.trimmingCharacters(in: .whitespaces).nilIfEmpty
        meta.genre = genre.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let picked = pickedImageData {
            // A chosen file wins — embed it directly (shows instantly, no download).
            meta.artworkData = picked
        } else {
            // Else, if the cover URL changed, clear the cache so the new one is fetched.
            let newCover = coverURL.trimmingCharacters(in: .whitespaces)
            if newCover != (album?.artworkURL?.absoluteString ?? "") {
                meta.artworkURL = newCover.isEmpty ? nil : URL(string: newCover)
                meta.artworkData = nil
            }
        }
        state.applyManualEdit(meta, to: albumID)
        dismiss()
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            pickedImageData = data
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Album-level credits in a sheet, opened by the "Credits" button.
struct CreditsSheet: View {
    let albumID: UUID
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    private var album: Album? { state.albums.first { $0.id == albumID } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album?.title ?? "Credits").font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Text("Album credits").font(.system(size: 12)).foregroundStyle(p.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.soft).foregroundStyle(p.muted)
            }
            ScrollView {
                AlbumCreditsView(albumID: albumID)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
        }
        .padding(Space.s5)
        .frame(width: 480, height: 560)
        .background(p.page)
    }
}

/// Per-track personnel (producer, vocals, …), opened by right-clicking a track.
struct TrackCreditsSheet: View {
    let albumID: UUID
    let title: String
    let index: Int
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    @State private var credits: [Credit] = []
    @State private var loading = true

    private var album: Album? { state.albums.first { $0.id == albumID } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Text("Track credits").font(.system(size: 12)).foregroundStyle(p.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.soft).foregroundStyle(p.muted)
            }
            content
        }
        .padding(Space.s5)
        .frame(width: 440, height: 480)
        .background(p.page)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if loading {
            VStack(spacing: Space.s3) {
                OrbLoader(size: 64)
                Text("Loading credits…").font(.system(size: 13)).foregroundStyle(p.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !credits.isEmpty {
            ScrollView { creditRows(credits) }.scrollIndicators(.hidden)
        } else if album?.discogsReleaseID == nil && album?.musicbrainzID == nil {
            emptyState("No per-track credits yet.",
                       hint: "Open the album\u{2019}s Credits and use \u{201C}Wrong album?\u{201D} to match it, or pick a Credits source in Settings.")
        } else if let alb = album?.credits, !alb.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("No track-specific credits — showing album credits.")
                    .font(.system(size: 12)).foregroundStyle(p.muted2)
                ScrollView { creditRows(alb) }.scrollIndicators(.hidden)
            }
        } else {
            emptyState("No credits found for this track.", hint: nil)
        }
    }

    private func creditRows(_ list: [Credit]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { c in
                HStack(alignment: .top, spacing: Space.s4) {
                    Text(c.role).font(.system(size: 13)).foregroundStyle(p.muted2)
                        .frame(width: 130, alignment: .leading)
                    Text(c.name).font(.system(size: 13, weight: .medium)).foregroundStyle(p.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                Divider().overlay(p.edgeSoft)
            }
        }
    }

    private func emptyState(_ title: String, hint: String?) -> some View {
        VStack(spacing: Space.s2) {
            Text(title).font(.system(size: 13)).foregroundStyle(p.muted)
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(p.muted2).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.s5)
    }

    private var cacheKey: String { "\(index)|\(title)" }

    private func load() async {
        // Use the saved credits if we've fetched them before — no network, survives relaunch.
        if let cached = album?.trackCredits?[cacheKey], !cached.isEmpty {
            credits = cached
            loading = false
            return
        }
        loading = true
        if let album {
            let fetched = await MetadataService().trackCredits(for: album, index: index, title: title)
            credits = fetched
            state.cacheTrackCredits(albumID: albumID, key: cacheKey, credits: fetched)
        }
        loading = false
    }
}

/// Manual matcher: search Discogs/iTunes and pick the correct release.
struct AlbumMatchSheet: View {
    let albumID: UUID
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var results: [MatchCandidate] = []
    @State private var loading = false
    @State private var applyingID: UUID?

    init(albumID: UUID, initialQuery: String) {
        self.albumID = albumID
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find the right album").font(.system(size: 15, weight: .bold))
                    Text("Search Discogs & iTunes, then pick the correct release.")
                        .font(.system(size: 12)).foregroundStyle(p.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.soft).foregroundStyle(p.muted)
            }

            HStack(spacing: Space.s2) {
                TextField("Artist – Album", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.vertical, 9).padding(.horizontal, Space.s3)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.glassFill))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
                    .onSubmit { search() }
                Button { search() } label: {
                    Text("Search").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(p.accentInk)
                        .padding(.vertical, 9).padding(.horizontal, Space.s4)
                        .background(Capsule().fill(p.accent))
                }.buttonStyle(.soft)
            }

            if loading {
                OrbLoadingRow(text: "Searching…", size: 64)
            } else if results.isEmpty {
                Text("No results yet — try refining the search.")
                    .font(.system(size: 13)).foregroundStyle(p.muted2)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: Space.s2) {
                        ForEach(results) { c in resultRow(c) }
                    }
                }.scrollIndicators(.hidden)
            }
        }
        .padding(Space.s5)
        .frame(width: 460, height: 520)
        .background(p.page)
        .task { if results.isEmpty { search() } }
    }

    private func resultRow(_ c: MatchCandidate) -> some View {
        Button {
            applyingID = c.id
            Task {
                await state.applyCandidate(c, to: albumID)
                applyingID = nil
                dismiss()
            }
        } label: {
            HStack(spacing: Space.s3) {
                AsyncImage(url: c.artworkURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(p.glassFill)
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title.isEmpty ? "Unknown" : c.title)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(c.subtitle).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer()
                if applyingID == c.id { OrbLoader(size: 64) }
            }
            .padding(Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 10)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.99, brighten: 0))
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        Task {
            let found = await MetadataService().candidates(query: q)
            results = found
            loading = false
        }
    }
}
