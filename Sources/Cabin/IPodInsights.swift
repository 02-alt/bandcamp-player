import SwiftUI

// MARK: - Library ⇄ iPod diff

/// What differs between the connected iPod and the Cabin library, matched by title + artist.
struct IPodDiff {
    let onlyOnIPod: [IPodAlbum]
    let onlyInLibrary: [Album]

    private static func key(_ title: String, _ artist: String) -> String {
        "\(title.lowercased())\u{1}\(artist.lowercased())"
    }

    static func compute(ipod: [IPodAlbum], library: [Album]) -> IPodDiff {
        let lib = library.filter { $0.source == .bandcamp || $0.hasLocalFiles || $0.url != nil }
        let libKeys = Set(lib.map { key($0.title, $0.artist) })
        let podKeys = Set(ipod.map { key($0.title, $0.artist) })
        return IPodDiff(
            onlyOnIPod: ipod.filter { !libKeys.contains(key($0.title, $0.artist)) },
            onlyInLibrary: lib.filter { !podKeys.contains(key($0.title, $0.artist)) }
        )
    }
}

/// Two columns: albums only on the iPod (import them) and albums only in Cabin (copy them over).
struct IPodDiffSheet: View {
    let diff: IPodDiff
    let device: IPodDevice
    let onClose: () -> Void
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Library ⇄ iPod").font(.system(size: 17, weight: .bold)).kerning(-0.3)
                    .foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
                Spacer()
                IconButton(system: "xmark", tip: "Close", action: onClose)
            }
            HStack(alignment: .top, spacing: Space.s4) {
                column(title: "ONLY ON THE IPOD", subtitle: "\(diff.onlyOnIPod.count) — not in Cabin") {
                    ForEach(diff.onlyOnIPod) { a in
                        row(title: a.title, artist: a.artist, action: "Import") {
                            state.downloadFromIPod([(a.title, a.artist, a.tracks)], device: device)
                        }
                    }
                }
                column(title: "ONLY IN YOUR LIBRARY", subtitle: "\(diff.onlyInLibrary.count) — not on the iPod") {
                    ForEach(diff.onlyInLibrary) { a in
                        row(title: a.title, artist: a.artist,
                            action: (a.hasLocalFiles || a.url != nil) ? "Add" : nil) {
                            state.addToIPod([a.id], device: device)
                        }
                    }
                }
            }
        }
        .padding(Space.s6)
        .frame(width: 640, height: 560)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(p.page))
    }

    @ViewBuilder private func column<C: View>(title: String, subtitle: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title).font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(p.muted2)
            ScrollView { LazyVStack(alignment: .leading, spacing: 0) { content() } }
                .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(title: String, artist: String, action: String?, _ run: @escaping () -> Void) -> some View {
        HStack(spacing: Space.s2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                Text(artist).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let action {
                Button(action: run) {
                    Text(action).font(.system(size: 10, weight: .bold)).foregroundStyle(p.accentInk)
                        .padding(.vertical, 3).padding(.horizontal, 8)
                        .background(Capsule().fill(p.accent))
                }.buttonStyle(.soft)
            }
        }
        .padding(.vertical, Space.s2)
    }
}

// MARK: - iPod recap

/// A "wrapped"-style snapshot of the device itself.
struct IPodRecapStats {
    let songs: Int
    let albumsCount: Int
    let artistsCount: Int
    let topArtists: [(name: String, tracks: Int)]
    let totalPlays: Int
    let mostPlayed: [IPodTrack]

    static func compute(_ albums: [IPodAlbum]) -> IPodRecapStats {
        let allTracks = albums.flatMap { $0.tracks }
        var artistCounts: [String: Int] = [:]
        for t in allTracks where !t.artist.isEmpty { artistCounts[t.artist, default: 0] += 1 }
        let topArtists = artistCounts.sorted { $0.value > $1.value }.prefix(5).map { (name: $0.key, tracks: $0.value) }
        let totalPlays = allTracks.reduce(0) { $0 + $1.playCount }
        let mostPlayed = allTracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(8).map { $0 }
        return IPodRecapStats(songs: allTracks.count, albumsCount: albums.count,
                              artistsCount: artistCounts.count, topArtists: topArtists,
                              totalPlays: totalPlays, mostPlayed: Array(mostPlayed))
    }
}

struct IPodRecapSheet: View {
    let stats: IPodRecapStats
    let device: IPodDevice
    let onImport: () -> Void
    let onClose: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            // Pinned header so the close button is always reachable, no matter how long the list is.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(size: 17, weight: .bold)).kerning(-0.3)
                        .foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
                    Text("What's on this iPod").font(.system(size: 11)).foregroundStyle(p.muted2)
                }
                Spacer()
                IconButton(system: "xmark", tip: "Close", action: onClose)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack(spacing: Space.s3) {
                        stat("\(stats.songs)", "songs")
                        stat("\(stats.albumsCount)", "albums")
                        stat("\(stats.artistsCount)", "artists")
                        stat("\(stats.totalPlays)", "plays")
                    }

                    if !stats.topArtists.isEmpty {
                        section("TOP ARTISTS") {
                            ForEach(Array(stats.topArtists.enumerated()), id: \.offset) { _, a in
                                HStack {
                                    Text(a.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                                    Spacer()
                                    Text("\(a.tracks)").font(.system(size: 11)).foregroundStyle(p.muted)
                                }.padding(.vertical, 2)
                            }
                        }
                    }

                    if stats.mostPlayed.isEmpty {
                        Text("No play counts on this iPod yet.").font(.system(size: 11)).foregroundStyle(p.muted2)
                    } else {
                        section("MOST PLAYED") {
                            ForEach(stats.mostPlayed) { t in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(t.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                                        Text(t.artist).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    Text("\(t.playCount)×").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.accent)
                                }.padding(.vertical, 2)
                            }
                        }
                        Button(action: onImport) {
                            Label("Import these plays into Cabin", systemImage: "square.and.arrow.down")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(p.accentInk)
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(Capsule().fill(p.accent))
                        }.buttonStyle(.soft)
                        Text("Adds your iPod listening to Cabin's history so it shows in your recap. Counts are read from the device and may be approximate.")
                            .font(.system(size: 10)).foregroundStyle(p.muted2)
                    }
                }
                .padding(.bottom, Space.s2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(Space.s6)
        .frame(width: 460, height: 620)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(p.page))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .heavy)).foregroundStyle(p.text)
            Text(label).font(.system(size: 10)).foregroundStyle(p.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.glassFill))
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title).font(.system(size: 11, weight: .bold)).kerning(1).foregroundStyle(p.muted2)
            content()
        }
    }
}

// MARK: - Import play counts

extension AppState {
    /// Pull the iPod's per-track play counts into Cabin's listening history (so they show in the
    /// recap/stats). Matched to a library album by title+artist when possible. Guarded to run once
    /// per device, and capped per track + overall so a heavily-played library can't bloat history.
    func importIPodPlayCounts(_ albums: [IPodAlbum], device: IPodDevice) {
        let flag = "ipodPlaysImported-\(device.serial ?? device.name)"
        if UserDefaults.standard.bool(forKey: flag) {
            showNotice("This iPod's plays were already imported."); return
        }
        // Join to library albums for a real albumID where the same record exists in Cabin.
        var libIndex: [String: UUID] = [:]
        for a in self.albums { libIndex["\(a.title.lowercased())\u{1}\(a.artist.lowercased())"] = a.id }

        var events: [PlayEvent] = []
        let perTrackCap = 20, totalCap = 6000
        outer: for al in albums {
            let albumID = libIndex["\(al.title.lowercased())\u{1}\(al.artist.lowercased())"]
            for t in al.tracks where t.playCount > 0 {
                let n = min(t.playCount, perTrackCap)
                let base = t.lastPlayed ?? Date()
                let secs = Double(t.durationMs) / 1000.0
                for k in 0..<n {
                    events.append(PlayEvent(albumID: albumID, albumTitle: al.title, artist: al.artist,
                                            trackTitle: t.title, date: base.addingTimeInterval(-Double(k) * 3600),
                                            seconds: max(secs, 60), duration: secs))
                    if events.count >= totalCap { break outer }
                }
            }
        }
        guard !events.isEmpty else { showNotice("No play counts to import from this iPod."); return }
        HistoryStore.appendBatch(events)
        invalidatePlayCounts()   // rebuild the memo so album play-counts reflect the import
        UserDefaults.standard.set(true, forKey: flag)
        showNotice("Imported \(events.count) iPod play\(events.count == 1 ? "" : "s") into your history.")
    }
}
