import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var updater: UpdaterModel
    @EnvironmentObject var bpmProgress: BPMProgress
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
    @State private var lastfmKey = RadioPrefs.lastfmKey ?? ""
    @State private var autoEnrich = MetadataPrefs.autoEnrich
    @State private var creditsSource = MetadataPrefs.creditsSource
    @AppStorage("ambientTheming") private var ambientTheming = true
    @AppStorage("shareCardAmbient") private var shareCardAmbient = true
    @AppStorage("offlineMode") private var offlineMode = false
    @AppStorage("menuBarPlayer") private var menuBarPlayer = true
    @AppStorage("vinylCrackle") private var vinylCrackle = true
    @AppStorage("lyricsEnabled") private var lyricsEnabled = true
    @AppStorage("animatedCover") private var animatedCover = false
    @AppStorage("crateArrows") private var crateArrows = false
    @AppStorage("ipodSkin") private var ipodSkin = IPodSkin.black.rawValue
    @AppStorage("tripBudget") private var tripBudget = 40

    // Profile
    @State private var cropTarget: CropTarget?
    @State private var shareCopied = false

    // Restore-removed picker
    @State private var showRestoreSheet = false

    // Which settings tab is showing — splits a very long screen into scannable groups.
    @State private var tab: SettingsTab = .general
    @State private var tripMode: TripMode = .new
    @State private var confirmingTripDelete = false
    @Namespace private var tripSeg
    /// The full ordered trip-candidate list, computed once (not per slider step). `tripPrepCandidates`
    /// is prefix-stable, so the budget slider just takes `prefix(tripBudget)` — no history/sort work
    /// on drag. Refreshed on appear and when a download batch finishes.
    @State private var tripAllCandidates: [Album] = []

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general, playback, library, accessibility, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general:       "General"
            case .playback:      "Playback"
            case .library:       "Library"
            case .accessibility: "Accessibility"
            case .about:         "About"
            }
        }
        var icon: String {
            switch self {
            case .general:       "slider.horizontal.3"
            case .playback:      "play.circle"
            case .library:       "music.note.list"
            case .accessibility: "accessibility"
            case .about:         "info.circle"
            }
        }
    }

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

            // Tab bar — turns one long scroll into four scannable groups.
            tabBar
                .padding(.horizontal, Space.s7)
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Space.s5)

            ScrollView {
                // Stack rhythm: cards are distinct sections → the large step (s6) between them.
                VStack(alignment: .leading, spacing: Space.s6) {
                    if tab == .general {
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
                    Divider().overlay(p.edgeSoft)
                    toggleRow("Ambient cover theming", isOn: $ambientTheming)
                    note("Tints the background glow with a colour pulled from the now-playing cover.")
                    Divider().overlay(p.edgeSoft)
                    toggleRow("Ambient share card", isOn: $shareCardAmbient)
                    note("Uses a blurred, cover-tinted backdrop on the shareable now-playing card. Off = a clean flat card.")
                }

                // Offline & travel — keep music playable with no connection.
                card("Offline & travel", icon: "airplane") {
                    toggleRow("Offline mode", isOn: $offlineMode)
                    note("Auto-downloads albums in FLAC as you play them, so recently-played music keeps working without a connection.")
                    Divider().overlay(p.edgeSoft)
                    tripPrepSection
                }

                // Now Playing — flat cover disc vs. full turntable.
                card("Now Playing", icon: "opticaldiscdrive") {
                    HStack(spacing: Space.s3) {
                        ForEach(NowPlayingStyle.allCases) { style in
                            choiceTile(title: style.label,
                                       subtitle: style.blurb,
                                       selected: state.nowPlayingStyle == style) {
                                nowPlayingPreview(style)
                            } action: {
                                withAnimation(.easeInOut(duration: 0.25)) { state.nowPlayingStyle = style }
                            }
                        }
                    }
                    note("Turntable turns the hero disc into a record on a platter, ringed by a progress track, with vinyl wear and surface crackle — and a 33/45/78 speed switch that shrinks it to a single and repitches the track.")
                    if state.nowPlayingStyle == .turntable {
                        Divider().overlay(p.edgeSoft)
                        toggleRow("Vinyl crackle", isOn: $vinylCrackle)
                        note("A faint record surface-noise loop under playback, thicker on albums you've played a lot. Drop a clip into Resources/Audio/vinyl-crackle to use a real recording instead of the built-in one.")
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

                // iPod — colour finish of the Classic replica. Last in General since the iPod view
                // only appears when a device is connected.
                card("iPod", icon: "ipod") {
                    HStack(alignment: .top, spacing: Space.s5) {
                        ForEach(IPodSkin.allCases) { s in
                            Button { ipodSkin = s.rawValue } label: {
                                VStack(spacing: 6) {
                                    iPodMini(skin: s)
                                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(p.accent, lineWidth: ipodSkin == s.rawValue ? 2.5 : 0)
                                            .padding(-4))
                                    Text(s.name).font(.system(size: 10, weight: ipodSkin == s.rawValue ? .semibold : .regular))
                                        .foregroundStyle(ipodSkin == s.rawValue ? p.text : p.muted).lineLimit(1)
                                }
                            }
                            .buttonStyle(.soft)
                            .accessibilityLabel("\(s.name) iPod")
                            .accessibilityAddTraits(ipodSkin == s.rawValue ? [.isSelected] : [])
                        }
                        Spacer()
                    }
                    note("The colour finish of the Classic iPod replica shown in the iPod view.")
                }

                    }   // end General

                    if tab == .playback {
                // Slowed + Reverb (DJ mode)
                card("Slowed + Reverb", icon: "dial.medium") {
                    toggleRow("Slowed + reverb engine", isOn: $player.djMode)
                    note("Slow tracks down (or speed them up) with the pitch bending like a turntable, then deepen the pitch further and wrap it in reverb for that dreamy slowed-and-reverb sound. Speed also appears as a fader on Now Playing. Pitch & reverb apply to downloaded tracks.")
                    if player.djMode {
                        Divider().overlay(p.edgeSoft)
                        row("Speed") {
                            Text(String(format: "%.2f×", player.speed))
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(p.muted)
                        }
                        Slider(value: $player.speed, in: 0.5...1.5, step: 0.01)
                            .accessibilityLabel("Playback speed")
                        // Scrolls horizontally so the preset row never clips its last pill on a
                        // narrow window (matches the EQ preset row below).
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.s2) {
                                pillButton("0.80× slowed", subtle: true) { player.speed = 0.80 }
                                pillButton("0.75× screwed", subtle: true) { player.speed = 0.75 }
                                pillButton("1.0× reset", subtle: true) { player.speed = 1.0 }
                                pillButton("1.25× fast", subtle: true) { player.speed = 1.25 }
                            }
                        }

                        Divider().overlay(p.edgeSoft)
                        row("Extra pitch") {
                            Text(player.pitch == 0 ? "0 st"
                                 : String(format: "%+.0f st", player.pitch))
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(p.muted)
                        }
                        Slider(value: $player.pitch, in: -12...12, step: 1)
                            .accessibilityLabel("Extra pitch, semitones")
                        note("An independent pitch shift on top of the speed drop — go lower for a deeper, more \u{201C}screwed\u{201D} timbre without changing the tempo.")

                        Divider().overlay(p.edgeSoft)
                        row("Reverb") {
                            Text(String(format: "%.0f%%", player.reverbMix))
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(p.muted)
                        }
                        Slider(value: $player.reverbMix, in: 0...100, step: 1)
                            .accessibilityLabel("Reverb wet/dry mix")

                        Divider().overlay(p.edgeSoft)
                        HStack(spacing: Space.s2) {
                            pillButton("Slowed + reverb") {
                                player.speed = 0.80; player.pitch = 0; player.reverbMix = 40
                            }
                            pillButton("Dry reset", subtle: true) {
                                player.speed = 1.0; player.pitch = 0; player.reverbMix = 0
                            }
                        }
                    }
                }

                // Transitions between tracks
                card("Transitions", icon: "shuffle") {
                    row("Between tracks") {
                        HStack(spacing: 3) {
                            ForEach(TransitionMode.allCases) { m in transitionButton(m) }
                        }
                        .padding(3)
                        .background(Capsule().fill(p.glassFill))
                        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                        .opacity(player.djMode ? 0.4 : 1)
                    }
                    if player.djMode {
                        note("Unavailable while DJ mode is on — the turntable engine plays one track at a time, so tracks can’t overlap. Turn DJ mode off to crossfade.")
                    } else {
                        note(player.transitionMode.blurb + ". Crossfade overlaps the end of each track with the start of the next; Beat-match also nudges their tempos together (pitch preserved) for owned local files. Manual skips still cut instantly.")
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

                // Equalizer
                card("Equalizer", icon: "slider.vertical.3") {
                    toggleRow("Equalizer", isOn: $player.eqEnabled)
                    EQEditor(gains: player.eqGains) { band, db in player.setEQBand(band, db) }
                        .padding(.top, Space.s3)
                        .opacity(player.eqEnabled ? 1 : 0.45)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            eqPresetButton("Auto")
                            ForEach(EQ.presets) { eqPresetButton($0.name) }
                            if player.eqPresetName == "Custom" { eqPresetButton("Custom") }
                        }
                    }
                    .padding(.top, Space.s2)
                    note("Drag a band to fine-tune (saved as Custom). Auto follows each album's genre; off leaves the audio untouched.")
                }

                // Menu bar
                card("Menu bar", icon: "menubar.rectangle") {
                    toggleRow("Show menu-bar player", isOn: $menuBarPlayer)
                    note("A now-playing item in the macOS menu bar with transport controls and volume. Press ⌘K anywhere for the command palette.")
                }

                // Lyrics
                card("Lyrics", icon: "quote.bubble") {
                    toggleRow("Time-synced lyrics", isOn: $lyricsEnabled)
                    note("Fetches synced lyrics from LRCLIB and shows a scrolling, tap-to-seek panel on Now Playing (tap the quote icon). Only time-synced lyrics are shown — tracks without them keep the disc.")
                }

                    }   // end Playback

                    if tab == .library {
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
                                pillButton("Restore removed", subtle: true) { showRestoreSheet = true }
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

                // Radio
                card("Radio", icon: "dot.radiowaves.left.and.right") {
                    row("Last.fm API key") {
                        HStack(spacing: Space.s2) {
                            pillButton("Get a free key", subtle: true) {
                                if let url = URL(string: "https://www.last.fm/api/account/create") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            SecureField("paste key", text: $lastfmKey)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 200)
                                .padding(.vertical, 7).padding(.horizontal, Space.s3)
                                .background(Capsule().fill(p.glassFill))
                                .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
                                .accessibilityLabel("Last.fm API key")
                                .onChange(of: lastfmKey) { _, v in
                                    RadioPrefs.lastfmKey = v.trimmingCharacters(in: .whitespaces)
                                }
                        }
                    }
                    note("Optional. Radio works fully without it — this makes mood & artist radio smarter. Tap “Get a free key”, sign in, and paste the API key it shows.")
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

                // Library health — find broken / unstreamable albums.
                card("Library health", icon: "stethoscope") {
                    switch state.health {
                    case .idle:
                        row("Check for broken, missing, or removed albums") {
                            pillButton("Scan library") { state.scanLibraryHealth() }
                        }
                        note("Verifies each album still plays — local files on disk, and that your Bandcamp albums haven't been removed by the artist. Removed albums you never downloaded are flagged as lost.")
                    case .scanning(let done, let total):
                        row("Checking \(done) of \(total)…") {
                            ProgressView().controlSize(.small)
                        }
                    case .done(let issues):
                        if issues.isEmpty {
                            row("Everything checks out") {
                                pillButton("Re-scan", subtle: true) { state.scanLibraryHealth() }
                            }
                            note("No broken or unstreamable albums found.")
                        } else {
                            row("\(issues.count) issue\(issues.count == 1 ? "" : "s") found") {
                                pillButton("Re-scan", subtle: true) { state.scanLibraryHealth() }
                            }
                            ForEach(issues) { issue in
                                Divider().overlay(p.edgeSoft)
                                HStack(spacing: Space.s3) {
                                    Circle().fill(healthDot(issue.kind)).frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(issue.title).font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(p.text).lineLimit(1)
                                        Text("\(issue.artist) · \(issue.reason)").font(.system(size: 11))
                                            .foregroundStyle(p.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    pillButton("Open", subtle: true) {
                                        state.screen = .grid
                                        state.openedAlbumID = issue.id
                                    }
                                    if issue.canRedownload {
                                        pillButton(issue.kind == .lost ? "Rescue" : "Re-download") {
                                            state.redownloadIssue(issue.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Tempo (BPM) — analyse every track so BPM shelves & beat features have data.
                card("Tempo (BPM)", icon: "metronome") {
                    if bpmProgress.running {
                        row("Analyzing \(bpmProgress.done) of \(bpmProgress.total) albums…") {
                            HStack(spacing: Space.s3) {
                                ProgressView().controlSize(.small)
                                pillButton("Stop", subtle: true) { state.stopBPMAnalysis() }
                            }
                        }
                        note("\(bpmProgress.analyzed) tracks analysed so far. Bandcamp tracks are streamed once to measure their tempo, then discarded.")
                    } else {
                        row("\(state.bpmKnownCount) track\(state.bpmKnownCount == 1 ? "" : "s") with known BPM") {
                            pillButton(state.bpmKnownCount == 0 ? "Analyze library" : "Analyze new") { state.analyzeLibraryBPM() }
                        }
                        note("Detects each track's tempo to power BPM smart shelves. Local/downloaded files are read directly; Bandcamp tracks are streamed once to measure, then discarded — so a full pass uses bandwidth and takes a while. Already-analysed tracks are skipped.")
                    }
                }

                    }   // end Library

                    if tab == .accessibility {
                // Navigation — explicit on-screen targets for people who can't (or prefer not to)
                // rely on swipe/scroll gestures.
                card("Navigation", icon: "hand.point.up.left") {
                    toggleRow("Album navigation arrows", isOn: $crateArrows)
                    note("Shows ◀ ▶ buttons next to Play in the crate for stepping through albums. Off by default — the cover deck is also swipeable, scrollable, clickable, and the ← / → keys always flip it.")
                }

                // Motion — the one continuously-animating decoration, plus a pointer to the system
                // controls the whole app already honours.
                card("Motion", icon: "figure.walk.motion") {
                    toggleRow("Flowing art backdrop (art mode)", isOn: $animatedCover)
                    note("Behind the fullscreen cover, a slow flowing colour gradient built from the artwork itself (Apple-Music style) — the cover stays crisp. Yoin's only always-on animation, so it lives here: turn it off for a still backdrop without disabling motion everywhere. Generated on-device.")
                    Divider().overlay(p.edgeSoft)
                    row("Reduce Motion") {
                        Text("Follows System Settings").font(.system(size: 12)).foregroundStyle(p.muted)
                    }
                    note("Yoin honours macOS ▸ System Settings ▸ Accessibility ▸ Display ▸ Reduce Motion everywhere — the crate flip, breathing orbs, flowing art backdrop and iPod animations all fall back to still frames or instant cuts when it's on.")
                    Divider().overlay(p.edgeSoft)
                    row("Reduce Transparency") {
                        Text("Follows System Settings").font(.system(size: 12)).foregroundStyle(p.muted)
                    }
                    note("With Reduce Transparency on, Yoin's frosted-glass panels, pills and mini-player fall back to solid fills for stronger contrast.")
                }
                    }   // end Accessibility

                    if tab == .about {
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
                    }   // end About
                }
                .padding(.horizontal, Space.s7)
                .padding(.bottom, Space.s7)
                .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)          // centre the column on wide windows
            }
            .scrollIndicators(.hidden)
        }
        .sheet(item: $cropTarget) { target in
            ProfileCropSheet(image: target.image,
                             onCancel: { cropTarget = nil },
                             onCrop: { data in
                state.profile.avatar = data
                state.saveProfile()
                cropTarget = nil
            })
        }
        .sheet(isPresented: $showRestoreSheet) {
            RestoreRemovedSheet(onDone: { showRestoreSheet = false })
                .environmentObject(state)
        }
    }

    // MARK: Tabs

    /// Segmented tab switcher. Each tab exposes the `.isSelected` trait so VoiceOver announces
    /// the current group, and the icon+label pair keeps targets comfortably clickable.
    private var tabBar: some View {
        HStack(spacing: Space.s2) {
            ForEach(SettingsTab.allCases) { t in
                let on = tab == t
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.system(size: 12, weight: .semibold))
                        Text(t.label).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(on ? p.text : p.muted)
                    .padding(.vertical, Space.s2).padding(.horizontal, Space.s4)
                    .background(Capsule().fill(on ? p.glassFill : .clear)
                        .overlay(Capsule().strokeBorder(on ? p.edge : .clear, lineWidth: 1)))
                    .hoverHighlight(active: on)
                }
                .buttonStyle(.soft(hover: 1.0, press: 0.96, brighten: 0))
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Settings").font(.system(size: 26, weight: .bold)).kerning(-0.4)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            IconButton(system: "xmark", tip: "Close settings") {
                withAnimation(.easeInOut(duration: 0.15)) { state.screen = .crate }
            }
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
        pickImageFile { img in cropTarget = CropTarget(image: img) }
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
    /// Trip-prep mode — what the primary action does with your offline batch.
    private enum TripMode: String, CaseIterable, Identifiable {
        case new, refresh, delete
        var id: String { rawValue }
        var label: String {
            switch self {
            case .new:     "Add new"
            case .refresh: "Refresh"
            case .delete:  "Delete"
            }
        }
    }

    /// "Prep for trip" — pick an album budget, then bulk-download a blend of most-played,
    /// recently-played and a few never-heard records so they're available offline on a plane/train.
    /// Once a batch is saved, a "you're trip-ready" banner + a gliding pill let you add more,
    /// refresh the files, or delete them to reclaim space.
    @ViewBuilder private var tripPrepSection: some View {
        let offline = state.offlineAlbums
        let hasOffline = !offline.isEmpty
        // "Add new" is the only option until something's been downloaded.
        let mode = hasOffline ? tripMode : .new
        // Slice the pre-computed candidate list — cheap, runs no history/filter/sort on drag.
        let picks = Array(tripAllCandidates.prefix(tripBudget))
        let offlineSize = ByteCountFormatter.string(
            fromByteCount: offline.reduce(Int64(0)) { $0 + state.estimatedSizeBytes($1) }, countStyle: .file)

        VStack(alignment: .leading, spacing: Space.s3) {
            // Heading + the budget (Add-new) or the size of what's already saved.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prep for trip").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
                    Text(hasOffline
                         ? "You're trip-ready. Add more, refresh them, or clear space."
                         : "Download a batch for offline listening — flights, trains, tunnels.")
                        .font(.system(size: 11)).foregroundStyle(p.muted2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(mode == .new ? "\(tripBudget)" : "\(offline.count)")
                        .font(.system(size: 30, weight: .bold).monospacedDigit()).foregroundStyle(p.text)
                    Text(mode == .new ? "album budget" : "offline")
                        .font(.system(size: 9, weight: .semibold)).kerning(0.5).textCase(.uppercase)
                        .foregroundStyle(p.muted2)
                }
            }

            // Ready banner + mode pill — the acknowledgement that a batch is saved.
            if hasOffline {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(p.accent)
                    Text("\(offline.count) album\(offline.count == 1 ? "" : "s") saved offline · ~\(offlineSize)")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(p.muted)
                }
                tripModePicker
            }

            // Mode-specific body.
            switch mode {
            case .new:              tripNewBody(picks)
            case .refresh, .delete: coverPeek(offline)
            }

            // Action, or live progress while a prep is running.
            if let tp = state.tripPrep {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(tp.done), total: Double(max(tp.total, 1))).tint(p.accent)
                    Text("\(mode == .refresh ? "Refreshing" : "Downloading") \(tp.done) of \(tp.total)…")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(p.muted2)
                }
            } else {
                tripActionButton(mode: mode, offline: offline, offlineSize: offlineSize, picks: picks)
            }
        }
        .onAppear { tripAllCandidates = state.tripPrepCandidates(count: 200) }
        // A finished download batch (tripPrep → nil) changes what's still downloadable — refresh.
        .onChange(of: state.tripPrep == nil) { _, done in
            if done { tripAllCandidates = state.tripPrepCandidates(count: 200) }
        }
    }

    /// A two-level gliding pill (modelled on the Free · Premium/Monthly·Annual reference):
    /// a plain "Add new" segment, plus a "Manage" segment that collapses to a summary and
    /// expands — when selected — into a filled container holding Refresh | Delete sub-pills.
    ///
    /// One *persistent* accent highlight follows the selected zone (single-source matched
    /// geometry, like the app's nav bars) so it slides **and** grows in one continuous morph
    /// instead of two capsules cross-fading; a second `page` highlight slides between the
    /// sub-pills. The filled state maps the reference's black-pill/white-text to our dark theme,
    /// where `accent` is near-white and `accentInk` near-black.
    private var tripModePicker: some View {
        let managing = tripMode != .new
        return HStack(spacing: 4) {
            // Left — Add new. Its clear background is the highlight's source when selected.
            Text("Add new")
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .foregroundStyle(managing ? p.muted : p.accentInk)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Color.clear.matchedGeometryEffect(id: "tripHL", in: tripSeg, isSource: !managing))
                .contentShape(Capsule())
                .hoverHighlight(active: !managing)
                .modifier(LinkCursor())
                .onTapGesture { withAnimation(Motion.fluid) { tripMode = .new } }
                .accessibilityLabel("Add new albums")
                .accessibilityAddTraits(managing ? [] : [.isSelected])

            // Right — Manage. Sub-pills stay laid out and cross-fade with the collapsed summary.
            ZStack {
                HStack(spacing: 3) {
                    tripSubPill(.refresh)
                    tripSubPill(.delete)
                }
                .padding(3)
                .opacity(managing ? 1 : 0)
                .allowsHitTesting(managing)
                .background {
                    if managing {   // the sliding sub-pill highlight (dark, sits on the accent fill)
                        Capsule().fill(p.page).matchedGeometryEffect(id: "tripSubHL", in: tripSeg, isSource: false)
                    }
                }

                VStack(spacing: 1) {
                    Text("Manage").font(.system(size: 12, weight: .semibold))
                    Text("Refresh · Delete").font(.system(size: 9, weight: .medium)).foregroundStyle(p.muted2)
                }
                .foregroundStyle(p.muted)
                .opacity(managing ? 0 : 1)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.clear.matchedGeometryEffect(id: "tripHL", in: tripSeg, isSource: managing))
            .contentShape(Capsule())
            .hoverHighlight(active: managing)
            .modifier(LinkCursor())
            .onTapGesture { if !managing { withAnimation(Motion.fluid) { tripMode = .refresh } } }
            .accessibilityLabel("Manage offline downloads")
        }
        .padding(4)
        // The one accent highlight morphs to whichever zone is the source (add-new / manage).
        .background(Capsule().fill(p.accent).matchedGeometryEffect(id: "tripHL", in: tripSeg, isSource: false))
        .background(Capsule().fill(p.glassFill.opacity(0.5)))
        .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
    }

    /// A sub-pill inside the expanded "Manage" container. Active = a raised dark `page` pill (via
    /// the sliding `tripSubHL` highlight) with light (or red, for delete) text; inactive = muted
    /// dark ink on the light accent container, with a hover fill so it reads as clickable.
    private func tripSubPill(_ m: TripMode) -> some View {
        let active = tripMode == m
        return Text(m.label)
            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            .foregroundStyle(active ? (m == .delete ? Color.red : p.text) : p.accentInk.opacity(0.55))
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Color.clear.matchedGeometryEffect(id: "tripSubHL", in: tripSeg, isSource: active))
            .contentShape(Capsule())
            .hoverHighlight(active: active)
            .modifier(LinkCursor())
            .onTapGesture { withAnimation(Motion.fluid) { tripMode = m } }
            .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// The "Add new" flow: budget slider, a cover peek of the mix, and the familiar/new legend.
    /// `picks` is passed in (sliced from the cached candidate list) so nothing recomputes on drag.
    @ViewBuilder private func tripNewBody(_ picks: [Album]) -> some View {
        let bytes = picks.reduce(Int64(0)) { $0 + state.estimatedSizeBytes($1) }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let newCount = picks.filter { state.playCount(for: $0) == 0 }.count
        let familiar = picks.count - newCount

        Slider(value: Binding(get: { Double(tripBudget) }, set: { tripBudget = Int($0) }),
               in: 5...200, step: 5)
            .accessibilityLabel("Trip album budget")

        if picks.isEmpty {
            Text("Everything's already downloaded — you're trip-ready.")
                .font(.system(size: 12)).foregroundStyle(p.muted)
        } else {
            coverPeek(picks)
            HStack(spacing: Space.s4) {
                legendDot(count: familiar, label: "familiar", filled: true)
                legendDot(count: newCount, label: "new", filled: false)
                Spacer()
                Text("~\(size)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(p.muted)
            }
        }
    }

    /// A row of overlapping album covers, capped at nine with a "+N" tail.
    private func coverPeek(_ albums: [Album]) -> some View {
        HStack(spacing: -14) {
            ForEach(albums.prefix(9)) { a in
                AlbumArt(album: a, corner: 6)
                    .frame(width: 46, height: 46)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(p.page, lineWidth: 2))
            }
            if albums.count > 9 {
                Text("+\(albums.count - 9)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(p.muted)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(p.glassFill))
                    .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
                    .padding(.leading, 4)
            }
        }
    }

    /// The primary button, whose action and styling follow the selected mode.
    @ViewBuilder private func tripActionButton(mode: TripMode, offline: [Album],
                                               offlineSize: String, picks: [Album]) -> some View {
        switch mode {
        case .new:
            Button { state.prepForTrip(count: tripBudget) } label: {
                tripButtonLabel(icon: "arrow.down.circle.fill",
                                text: picks.isEmpty ? "Nothing to download"
                                                    : "Download \(picks.count) album\(picks.count == 1 ? "" : "s")",
                                fill: p.accent, ink: p.accentInk)
            }
            .buttonStyle(.soft).opacity(picks.isEmpty ? 0.4 : 1).disabled(picks.isEmpty)

        case .refresh:
            Button { state.refreshOfflineAlbums() } label: {
                tripButtonLabel(icon: "arrow.clockwise.circle.fill",
                                text: "Refresh \(offline.count) offline album\(offline.count == 1 ? "" : "s")",
                                fill: p.accent, ink: p.accentInk)
            }
            .buttonStyle(.soft)

        case .delete:
            let size = offlineSize
            Button(role: .destructive) { confirmingTripDelete = true } label: {
                tripButtonLabel(icon: "trash.fill",
                                text: "Delete \(offline.count) download\(offline.count == 1 ? "" : "s") · ~\(size)",
                                fill: .red, ink: .white)
            }
            .buttonStyle(.soft)
            .confirmationDialog("Delete all offline downloads?",
                                isPresented: $confirmingTripDelete, titleVisibility: .visible) {
                Button("Delete \(offline.count) download\(offline.count == 1 ? "" : "s")", role: .destructive) {
                    state.deleteOfflineAlbums()
                    tripMode = .new
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Frees ~\(size). The albums stay in your library and can be downloaded again.")
            }
        }
    }

    private func tripButtonLabel(icon: String, text: String, fill: Color, ink: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 13, weight: .bold)).foregroundStyle(ink)
        .frame(maxWidth: .infinity).padding(.vertical, 11)
        .background(Capsule().fill(fill))
    }

    /// A small coloured-dot + count label for the trip-prep mix legend.
    private func legendDot(count: Int, label: String, filled: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(filled ? p.accent : p.glassFill)
                .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: filled ? 0 : 1))
                .frame(width: 9, height: 9)
            Text("\(count) \(label)").font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted)
        }
    }

    /// Status dot colour for a library-health row: red = lost (gone, no copy), green = archived
    /// (gone but saved offline), orange = a disk problem we might fix.
    private func healthDot(_ kind: LibraryIssue.Kind) -> Color {
        switch kind {
        case .lost: return Color(red: 0.90, green: 0.28, blue: 0.24)
        case .archived: return Color(red: 0.30, green: 0.72, blue: 0.45)
        case .missingFile, .noSource: return Color(red: 0.95, green: 0.62, blue: 0.20)
        }
    }

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

    /// A small iPod silhouette in a skin's finish, so the colour picker shows the real look.
    private func iPodMini(skin: IPodSkin) -> some View {
        let w: CGFloat = 46
        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(white: 0.97))
                .frame(width: w * 0.74, height: w * 0.52)
                .padding(.top, w * 0.12)
            Spacer(minLength: 0)
            Circle()
                .fill(RadialGradient(colors: skin.wheel, center: .center, startRadius: 0, endRadius: w * 0.24))
                .frame(width: w * 0.48, height: w * 0.48)
                .overlay(Circle().fill(skin.wheel.last ?? .gray).overlay(Circle().fill(.black.opacity(0.12)))
                    .frame(width: w * 0.17, height: w * 0.17))
                .padding(.bottom, w * 0.12)
        }
        .frame(width: w, height: w * 1.5)
        .background(LinearGradient(colors: skin.body, startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: w * 0.14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: w * 0.14, style: .continuous)
            .strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    @ViewBuilder
    private func nowPlayingPreview(_ style: NowPlayingStyle) -> some View {
        switch style {
        case .flat:
            // A clean cover disc with a progress ring.
            ZStack {
                Circle().strokeBorder(p.text.opacity(0.18), lineWidth: 2).frame(width: 40, height: 40)
                Circle().trim(from: 0, to: 0.65)
                    .stroke(p.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 40, height: 40)
                Circle().fill(p.text.opacity(0.85)).frame(width: 30, height: 30)
                Circle().fill(p.page).frame(width: 6, height: 6)
            }
        case .turntable:
            // A record with a tonearm reaching in from the top-right.
            ZStack {
                Circle().fill(Color.black).frame(width: 40, height: 40)
                Circle().strokeBorder(p.text.opacity(0.12), lineWidth: 1).frame(width: 30, height: 30)
                Circle().fill(p.text.opacity(0.85)).frame(width: 16, height: 16)
                Circle().fill(p.page).frame(width: 4, height: 4)
                Capsule().fill(p.muted).frame(width: 26, height: 3)
                    .rotationEffect(.degrees(34))
                    .offset(x: 14, y: -12)
            }
        case .firstListen:
            // A centred cover with lyric lines reading down the right.
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(p.text.opacity(0.85)).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(p.text.opacity(0.5 - Double(i) * 0.1))
                            .frame(width: 26 - CGFloat(i) * 4, height: 2.5)
                    }
                }
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

    private func eqPresetButton(_ name: String) -> some View {
        let on = player.eqPresetName == name
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { player.eqPresetName = name }
        } label: {
            Text(name).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? p.text : p.muted)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(Capsule().fill(on ? p.glassFill : .clear)
                    .overlay(Capsule().strokeBorder(on ? p.edge : .clear, lineWidth: 1)))
                .hoverHighlight(active: on)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
        .accessibilityLabel("EQ preset: \(name)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func transitionButton(_ m: TransitionMode) -> some View {
        let on = player.transitionMode == m
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { player.transitionMode = m }
        } label: {
            Text(m.label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? p.text : p.muted)
                .padding(.vertical, 6).padding(.horizontal, 14)
                .background(Capsule().fill(on ? p.glassFill : .clear)
                    .overlay(Capsule().strokeBorder(on ? p.edge : .clear, lineWidth: 1)))
                .hoverHighlight(active: on)
        }
        .buttonStyle(.soft(hover: 1.0, press: 0.94, brighten: 0))
        .disabled(player.djMode)
        .help(player.djMode ? "Turn DJ mode off to use transitions" : "")
        .accessibilityLabel("Transitions: \(m.label)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
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
