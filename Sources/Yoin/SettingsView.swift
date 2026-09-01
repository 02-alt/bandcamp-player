import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var updater: UpdaterModel
    @Environment(\.palette) private var p

    /// e.g. "1.0" from the bundle's CFBundleShortVersionString.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Cap the settings column so it stays readable (and centred) on wide windows.
    private static let contentMaxWidth: CGFloat = 860

    private var downloadableCount: Int { state.albums.filter { $0.canDownload }.count }
    private var downloadedCount: Int { state.albums.filter { $0.isDownloaded }.count }

    @State private var discogsToken = MetadataPrefs.discogsToken ?? ""
    @State private var autoEnrich = MetadataPrefs.autoEnrich
    @State private var creditsSource = MetadataPrefs.creditsSource

    // Profile
    @State private var cropImage: NSImage?
    @State private var showCrop = false
    @State private var shareCopied = false

    private var year: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned header — the title + close button stay on top while sections scroll beneath.
            header
                .padding(.horizontal, Space.s7)
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)          // centre the column on wide windows
                .padding(.top, Space.s7)
                .padding(.bottom, Space.s5)

            ScrollView {
                // Stack rhythm: cards are distinct sections → the large step (s6) between them.
                VStack(alignment: .leading, spacing: Space.s6) {
                    // Profile
                card("Profile", icon: "person.crop.circle") {
                    HStack(spacing: Space.s4) {
                        avatar
                        VStack(alignment: .leading, spacing: Space.s2) {
                            TextField("Your name", text: Binding(
                                get: { state.profile.name },
                                set: { state.profile.name = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(p.text)
                            .onSubmit { state.saveProfile() }
                            .frame(maxWidth: 220, alignment: .leading)
                            .accessibilityLabel("Your display name")

                            HStack(spacing: Space.s3) {
                                pillButton(state.profile.avatar == nil ? "Add photo" : "Change photo",
                                           subtle: true) { pickPhoto() }
                                if state.profile.avatar != nil {
                                    pillButton("Remove", subtle: true) {
                                        state.profile.avatar = nil; state.saveProfile()
                                    }
                                }
                            }
                        }
                        Spacer()
                    }
                    Divider().overlay(p.edgeSoft)
                    row("Your \(String(year)) recap") {
                        HStack(spacing: Space.s3) {
                            pillButton("Open recap", subtle: true) {
                                withAnimation(.easeInOut(duration: 0.15)) { state.screen = .recap }
                            }
                            pillButton(shareCopied ? "Link copied" : "Share top 10") { shareTopTen() }
                        }
                    }
                    note("Copies a private link — your listening data rides inside the URL, so nothing is uploaded. Each album links to Bandcamp so friends can support the artists.")
                }

                // Listening stats — always-on counterpart to the year-end recap.
                ListeningStatsCard()

                // Appearance — visual theme picker.
                card("Appearance", icon: "paintbrush") {
                    HStack(spacing: Space.s3) {
                        choiceTile(title: "Light", selected: state.scheme == .light) {
                            themePreview(.light)
                        } action: { if state.scheme != .light { state.toggleScheme() } }
                        choiceTile(title: "Dark", selected: state.scheme == .dark) {
                            themePreview(.dark)
                        } action: { if state.scheme != .dark { state.toggleScheme() } }
                    }
                }

                // Cover carousel — the new switch, shown as two visual choices.
                card("Cover carousel", icon: "square.stack") {
                    HStack(spacing: Space.s3) {
                        ForEach(CrateStyle.allCases) { style in
                            choiceTile(title: style.label,
                                       subtitle: style.blurb,
                                       selected: state.crateStyle == style) {
                                carouselPreview(style)
                            } action: {
                                withAnimation(.easeInOut(duration: 0.2)) { state.crateStyle = style }
                            }
                        }
                    }
                }

                // DJ mode
                card("DJ mode", icon: "dial.medium") {
                    toggleRow("Turntable speed control", isOn: $player.djMode)
                    note("Slow the track down or speed it up — pitch bends with the tempo like a turntable. A speed fader appears on the Now Playing screen.")
                    if player.djMode {
                        Divider().overlay(p.edgeSoft)
                        row("Speed") {
                            Text(String(format: "%.2f×", player.speed))
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(p.muted)
                        }
                        Slider(value: $player.speed, in: 0.5...1.5, step: 0.01)
                            .accessibilityLabel("Playback speed")
                        HStack(spacing: Space.s2) {
                            pillButton("0.75× screwed", subtle: true) { player.speed = 0.75 }
                            pillButton("1.0× reset", subtle: true) { player.speed = 1.0 }
                            pillButton("1.25× fast", subtle: true) { player.speed = 1.25 }
                        }
                    }
                }

                // Mini player
                card("Mini player", icon: "pip") {
                    row("Style") {
                        HStack(spacing: 3) {
                            ForEach(MiniPlayerStyle.allCases) { s in miniStyleButton(s) }
                        }
                        .padding(3)
                        .background(Capsule().fill(p.glassFill))
                        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                    }
                    note("Cover = full-art card. Turntable = a spinning vinyl with the info beside it. Open it with the mini-player button in the player bar.")
                }

                // Bandcamp
                card("Bandcamp", icon: "link") {
                    if state.isConnected {
                        row("Account") {
                            HStack(spacing: 7) {
                                Circle().fill(p.text).frame(width: 7, height: 7)
                                Text("Connected").font(.system(size: 13)).foregroundStyle(p.muted)
                            }
                            .accessibilityElement()
                            .accessibilityLabel("Account connected")
                        }
                        Divider().overlay(p.edgeSoft)
                        row("\(state.albums.filter { $0.source == .bandcamp }.count) albums synced") {
                            HStack(spacing: Space.s3) {
                                let syncing = state.sync == .syncing
                                Button { Task { await state.syncBandcamp(announce: true) } } label: {
                                    HStack(spacing: 6) {
                                        if syncing { OrbLoader(size: 14) }
                                        Text(syncing ? "Syncing…" : "Sync now").font(.system(size: 12, weight: .bold))
                                    }
                                    .foregroundStyle(p.accentInk)
                                    .padding(.vertical, 9).padding(.horizontal, Space.s4)
                                    .background(Capsule().fill(p.accent))
                                }
                                .buttonStyle(.soft).disabled(syncing)
                                pillButton("Disconnect", subtle: true) { state.disconnect() }
                            }
                        }
                        if !AppState.hiddenBandcamp.isEmpty {
                            Divider().overlay(p.edgeSoft)
                            row("\(AppState.hiddenBandcamp.count) removed album\(AppState.hiddenBandcamp.count == 1 ? "" : "s")") {
                                pillButton("Restore removed", subtle: true) { state.restoreRemovedBandcamp() }
                            }
                        }
                    } else {
                        row("Account") {
                            pillButton("Connect Bandcamp") { state.connect() }
                        }
                    }
                }

                // Import
                card("Import music", icon: "square.and.arrow.down") {
                    row("From your Mac") {
                        pillButton("Choose files or folder", subtle: true) { state.pickAndImport() }
                    }
                    Divider().overlay(p.edgeSoft)
                    row("From Apple Music") {
                        pillButton("Import purchased albums") { state.importFromAppleMusic() }
                    }
                    note("Pulls albums you own in the Apple Music app. Pick the whole library, an artist, or a single album. Track numbers in filenames are cleaned off titles automatically.")
                }

                // Metadata / credits
                card("Metadata", icon: "text.badge.checkmark") {
                    row("Credits source") {
                        HStack(spacing: 3) {
                            ForEach(CreditsSource.allCases, id: \.self) { s in
                                sourceButton(s)
                            }
                        }
                        .padding(3)
                        .background(Capsule().fill(p.glassFill))
                        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                    }
                    note(creditsSource == .musicbrainz
                         ? "MusicBrainz — free, no account or token needed."
                         : creditsSource == .discogs
                         ? "Discogs — richest credits, but needs a token below."
                         : "Automatic — uses Discogs if you\u{2019}ve added a token, otherwise MusicBrainz.")
                    Divider().overlay(p.edgeSoft)
                    row("Discogs token") {
                        SecureField("paste token", text: $discogsToken)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 200)
                            .padding(.vertical, 7).padding(.horizontal, Space.s3)
                            .background(Capsule().fill(p.glassFill))
                            .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                            .accessibilityLabel("Discogs API token")
                            .onChange(of: discogsToken) { _, v in
                                MetadataPrefs.discogsToken = v.trimmingCharacters(in: .whitespaces)
                            }
                    }
                    note("Free at discogs.com/settings/developers — enables full personnel credits (Tidal-style). Without it, covers & names still come from iTunes.")
                    Divider().overlay(p.edgeSoft)
                    toggleRow("Auto-enrich imports", isOn: $autoEnrich)
                        .onChange(of: autoEnrich) { _, v in MetadataPrefs.autoEnrich = v }
                    note("On import: fetch cover art, clean up the track/album name, and pull credits.")
                }

                // Downloads
                card("Downloads", icon: "arrow.down.circle") {
                    row("Folder") {
                        pillButton("Reveal in Finder") {
                            try? FileManager.default.createDirectory(at: AppState.libraryFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(AppState.libraryFolder)
                        }
                    }
                    Text(AppState.libraryFolder.path)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted2)
                    Divider().overlay(p.edgeSoft)
                    row("\(downloadedCount) downloaded · \(downloadableCount) remaining") {
                        pillButton("Download all in FLAC") { state.downloadAll() }
                            .opacity(downloadableCount == 0 ? 0.4 : 1)
                            .disabled(downloadableCount == 0)
                    }
                    note("Highest quality available, saved offline. Streaming is 128 kbps.")
                }

                // About
                card("About", icon: "info.circle") {
                    row("Yoin") {
                        HStack(spacing: Space.s3) {
                            Text("v\(appVersion) · macOS").font(.system(size: 12)).foregroundStyle(p.muted)
                            pillButton("Check for updates", subtle: true) {
                                updater.checkForUpdates()
                            }
                            .disabled(!updater.canCheckForUpdates)
                        }
                    }
                    Divider().overlay(p.edgeSoft)
                    row("Release notes") {
                        pillButton("What's new", subtle: true) {
                            state.showWhatsNew = true
                        }
                    }
                    note("The highlights from the latest update — the same card Yoin shows you after it updates.")
                    Divider().overlay(p.edgeSoft)
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Thanks").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                        note("Thanks to all my friends at 22 for their help and support. Everything at btbr is made with love — hope you'll like the app.")
                        note("— buildtoberemembered")
                    }
                }
                }
                .padding(.horizontal, Space.s7)
                .padding(.bottom, Space.s7)
                .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)          // centre the column on wide windows
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showCrop) {
            if let img = cropImage {
                ProfileCropSheet(image: img,
                                 onCancel: { showCrop = false; cropImage = nil },
                                 onCrop: { data in
                    state.profile.avatar = data
                    state.saveProfile()
                    showCrop = false
                    cropImage = nil
                })
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Settings").font(.system(size: 26, weight: .bold)).kerning(-0.4)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            IconButton(system: "xmark") {
                withAnimation(.easeInOut(duration: 0.15)) { state.screen = .crate }
            }
            .accessibilityLabel("Close settings")
        }
    }

    // MARK: Profile helpers

    private var avatar: some View {
        ZStack {
            Circle().fill(p.glassFill)
            if let img = state.profile.avatarImage {
                Image(nsImage: img).resizable().scaledToFill()
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 26)).foregroundStyle(p.muted2)
            }
            Circle().strokeBorder(p.edgeSoft, lineWidth: 1)
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }

    private func pickPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            cropImage = img
            showCrop = true
        }
    }

    private func shareTopTen() {
        let recap = RecapBuilder.build(year: year, albums: state.albums)
        guard let url = RecapShare.url(for: recap, name: state.profile.name) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { shareCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeIn(duration: 0.2)) { shareCopied = false }
        }
    }

    // MARK: Building blocks

    /// A titled section card. The icon makes sections scannable at a glance.
    private func card(_ title: String, icon: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s2) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.muted2).frame(width: 16)
                Text(title.uppercased()).font(.system(size: 11, weight: .bold)).kerning(1)
                    .foregroundStyle(p.muted2)
            }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)

            // Related controls inside a card → the small step (s3) between them.
            VStack(alignment: .leading, spacing: Space.s3) { content() }
                .padding(Space.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(p.glassFill))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
        }
    }

    private func row(_ label: String, @ViewBuilder _ trailing: () -> some View) -> some View {
        HStack {
            Text(label).font(.system(size: 14, weight: .medium))
            Spacer()
            trailing()
        }
    }

    /// A labelled toggle — the label is the control's accessible name.
    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        row(label) {
            Toggle("", isOn: isOn).labelsHidden()
                .accessibilityLabel(label)
        }
    }

    /// Small explanatory caption. Muted, but ≥ the contrast floor for secondary text.
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(p.muted2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A big, visual pick-one tile. Selected state is shown by BOTH an accent border and a
    /// checkmark (never colour alone), and it exposes the `.isSelected` trait to VoiceOver.
    private func choiceTile(title: String,
                            subtitle: String? = nil,
                            selected: Bool,
                            @ViewBuilder preview: () -> some View,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s3) {
                preview()
                    .frame(height: 60)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.page))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? p.accent : p.muted2)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(p.muted2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? p.glassFill : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? p.accent : p.edgeSoft, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.soft)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Tile previews

    private func themePreview(_ scheme: ColorScheme) -> some View {
        let pal = Palette(scheme: scheme)
        return ZStack {
            pal.page
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(pal.text).frame(width: 34, height: 6)
                RoundedRectangle(cornerRadius: 3).fill(pal.muted).frame(width: 24, height: 5)
                Capsule().fill(pal.accent).frame(width: 18, height: 8)
            }
        }
    }

    @ViewBuilder
    private func carouselPreview(_ style: CrateStyle) -> some View {
        switch style {
        case .coverflow:
            // Three covers fanned to the right.
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(p.text.opacity(0.9 - Double(i) * 0.28))
                        .frame(width: 30, height: 30)
                        .rotation3DEffect(.degrees(-28), axis: (x: 0, y: 1, z: 0))
                        .offset(x: CGFloat(i) * 14 - 10)
                        .zIndex(Double(3 - i))
                }
            }
        case .vinyl:
            // A disc slipped out to the left of a sleeve.
            ZStack {
                Circle().fill(Color.black)
                    .overlay(Circle().fill(p.text).frame(width: 10, height: 10))
                    .overlay(Circle().strokeBorder(p.text.opacity(0.15), lineWidth: 1).padding(4))
                    .frame(width: 34, height: 34)
                    .offset(x: -14)
                RoundedRectangle(cornerRadius: 3).fill(p.text.opacity(0.9))
                    .frame(width: 30, height: 30)
                    .offset(x: 8)
            }
        case .spread:
            // Many covers spread evenly, shrinking little.
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(p.text.opacity(0.9 - Double(i) * 0.15))
                        .frame(width: 24, height: 24)
                        .rotation3DEffect(.degrees(-22), axis: (x: 0, y: 1, z: 0))
                        .offset(x: CGFloat(i) * 12 - 24)
                        .zIndex(Double(5 - i))
                }
            }
        }
    }

    private func miniStyleButton(_ s: MiniPlayerStyle) -> some View {
        let on = state.miniPlayerStyle == s
        return Button {
            state.miniPlayerStyle = s
        } label: {
            Text(s.label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? p.text : p.muted)
                .padding(.vertical, 6).padding(.horizontal, 14)
                .background(Capsule().fill(on ? p.glassFill : .clear)
                    .overlay(Capsule().strokeBorder(on ? p.edge : .clear, lineWidth: 1)))
                .hoverHighlight(active: on)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
        .accessibilityLabel(s.label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func sourceButton(_ s: CreditsSource) -> some View {
        let on = creditsSource == s
        return Button {
            creditsSource = s
            MetadataPrefs.creditsSource = s
        } label: {
            Text(s.label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? p.text : p.muted)
                .padding(.vertical, 6).padding(.horizontal, 14)
                .background(Capsule().fill(on ? p.glassFill : .clear)
                    .overlay(Capsule().strokeBorder(on ? p.edge : .clear, lineWidth: 1)))
                .hoverHighlight(active: on)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
        .accessibilityLabel(s.label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func pillButton(_ label: String, subtle: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .bold))
                .foregroundStyle(subtle ? p.muted : p.accentInk)
                .padding(.vertical, 9).padding(.horizontal, Space.s4)
                .background(Capsule().fill(subtle ? p.glassFill : p.accent))
                .overlay(Capsule().strokeBorder(subtle ? p.edgeSoft : .clear, lineWidth: 1))
        }.buttonStyle(.soft)
    }
}
