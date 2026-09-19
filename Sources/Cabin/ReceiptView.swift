import SwiftUI
import AppKit

/// The monthly "listening receipt" — a printed ticket of the month's top plays, revealed with a
/// boarding-pass-style animation: a blurred montage of the month's covers brightens in, then the
/// ticket slides up from the bottom (header first), and the actions rise in last. Auto-shown once
/// a month (see `MonthlyReceipt`) or re-opened from the month's "Best of" playlist.
struct ReceiptView: View {
    let month: ReceiptMonth
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var shareAnchor = NSViewAnchor()

    // Choreography.
    @State private var backdropIn = false   // opacity + initial zoom-in of the cover wall
    @State private var drift = false        // slow continuing Ken Burns drift
    @State private var cardUp = false
    @State private var buttonsIn = false

    // Built once on appear — RecapBuilder reads/decodes the whole history from disk, so we must
    // not rebuild it on every body/backdrop pass during the multi-stage reveal animation.
    @State private var built: Recap?
    private var recap: Recap {
        built ?? RecapBuilder.build(year: month.year, month: month.month, albums: state.albums)
    }

    var body: some View {
        ZStack {
            backdrop
                .scaleEffect((backdropIn ? 1.0 : 1.22) + (drift ? 0.06 : 0))   // zoom-in, then slow drift
                .opacity(backdropIn ? 1 : 0)
                .ignoresSafeArea()
                .clipped()
            Rectangle().fill(.black.opacity(backdropIn ? 0.5 : 0.92))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            // The ticket, sliding up from below and settling a little above centre.
            ReceiptTicket(recap: recap, month: month, palette: p)
                .offset(y: cardUp ? -28 : 820)

            // Actions pinned near the bottom, rising in after the ticket lands.
            VStack {
                Spacer()
                actions
                    .opacity(buttonsIn ? 1 : 0)
                    .offset(y: buttonsIn ? 0 : 26)
                    .padding(.bottom, Space.s8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.palette, p)
        .background {
            Button("") { close() }.keyboardShortcut(.escape, modifiers: []).hidden()
        }
        .onAppear {
            if built == nil { built = RecapBuilder.build(year: month.year, month: month.month, albums: state.albums) }
            reveal()
        }
    }

    // MARK: Layers

    /// A wall of the month's covers that zooms in (the "map zoom-in" equivalent).
    @ViewBuilder private var backdrop: some View {
        GeometryReader { geo in
            let cols = 3
            let cell = geo.size.width / CGFloat(cols)
            let rows = max(1, Int(ceil(geo.size.height / cell)) + 1)
            let items = recap.items
            ZStack {
                p.page
                if !items.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(0..<rows, id: \.self) { r in
                            HStack(spacing: 0) {
                                ForEach(0..<cols, id: \.self) { c in
                                    let idx = (r * cols + c) % items.count
                                    cover(items[idx])
                                        .scaledToFill()
                                        .frame(width: cell, height: cell)
                                        .clipped()
                                }
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: CGFloat(rows) * cell, alignment: .top)
                    .blur(radius: 8)
                }
                if let a = state.ambient { a.opacity(0.2).blendMode(.plusLighter) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder private func cover(_ item: RecapItem) -> some View {
        if let d = item.artworkData, let img = NSImage(data: d) {
            Image(nsImage: img).resizable()
        } else if let url = item.artworkURL {
            CachedRemoteImage(url: url) { Rectangle().fill(p.page) }
        } else {
            LinearGradient(colors: [p.blob1, p.page], startPoint: .top, endPoint: .bottom)
        }
    }

    private var actions: some View {
        HStack(spacing: Space.s3) {
            Button { addPlaylist() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.plus").font(.system(size: 12))
                    Text("Add \(SmartRule.monthName(month.month)) playlist").font(.system(size: 13, weight: .bold)).lineLimit(1)
                }
                .foregroundStyle(p.accentInk)
                .padding(.vertical, 11).padding(.horizontal, Space.s5)
                .background(Capsule().fill(p.accent))
            }
            .buttonStyle(.soft).disabled(recap.isEmpty)

            Button { share() } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 14)).foregroundStyle(p.text)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(p.glassFill))
                    .overlay(Circle().strokeBorder(p.edgeSoft, lineWidth: 1))
            }
            .buttonStyle(.soft).help("Share receipt")
            .background(NSViewAnchorRep(anchor: shareAnchor))

            Button { close() } label: {
                Text("Done").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    .padding(.vertical, 11).padding(.horizontal, Space.s4)
                    .background(Capsule().fill(p.glassFill))
                    .overlay(Capsule().strokeBorder(p.edgeSoft, lineWidth: 1))
            }
            .buttonStyle(.soft)
        }
    }

    // MARK: Choreography

    private func reveal() {
        guard !reduceMotion else { backdropIn = true; cardUp = true; buttonsIn = true; return }
        // Map-style zoom-in of the cover wall, then a slow continuing drift.
        withAnimation(.easeOut(duration: 0.7)) { backdropIn = true }
        withAnimation(.easeInOut(duration: 9).delay(0.6).repeatForever(autoreverses: true)) { drift = true }
        // The pass scrolls up from below (header first) and settles.
        withAnimation(.spring(response: 1.05, dampingFraction: 0.88).delay(0.35)) { cardUp = true }
        withAnimation(.easeOut(duration: 0.45).delay(1.25)) { buttonsIn = true }
    }

    private func close() {
        guard !reduceMotion else { state.receiptMonth = nil; return }
        withAnimation(.easeIn(duration: 0.3)) { cardUp = false; buttonsIn = false; backdropIn = false; drift = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { state.receiptMonth = nil }
    }

    private func addPlaylist() {
        state.createSmartPlaylist(.bestOf(year: month.year, month: month.month))
        close()
    }

    @MainActor private func share() {
        let ticket = ReceiptTicket(recap: recap, month: month, palette: p)
            .frame(width: 360)
            .padding(Space.s6)
            .background(p.page)
        let renderer = ImageRenderer(content: ticket.environment(\.palette, p))
        renderer.scale = 2
        guard let image = renderer.nsImage else { state.showNotice("Couldn't create the receipt image."); return }
        ShareCard.present(image, anchorView: shareAnchor.view)
    }
}

/// A minimalist monthly-recap card that matches the app's dark surfaces: one uniform panel
/// (the cover is the only colour), strong type hierarchy, and generous, consistent spacing.
/// Self-contained (explicit palette) so it renders on-screen and for the share image.
struct ReceiptTicket: View {
    let recap: Recap
    let month: ReceiptMonth
    let palette: Palette
    var accent: Color = .clear   // unused — the card is intentionally monochrome

    private var p: Palette { palette }
    private var surface: Color { palette.scheme == .dark ? Color(white: 0.13) : Color(white: 0.965) }
    private var minutes: Int { Int((recap.totalSeconds / 60).rounded()) }
    private var tracks: Int { recap.items.reduce(0) { $0 + $1.plays } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if recap.isEmpty {
                Text("No plays logged this month.").font(.system(size: 14)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else {
                stats
                Rectangle().fill(p.edgeSoft).frame(height: 1)
                if let artist = recap.topArtist {
                    HStack {
                        Text("Top artist").font(.system(size: 13)).foregroundStyle(p.muted)
                        Spacer()
                        Text(artist).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    }
                }
                mostPlayed
            }
        }
        .padding(24)
        .frame(width: 330)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 36, y: 22)
    }

    private var header: some View {
        HStack(spacing: 14) {
            coverThumb
            VStack(alignment: .leading, spacing: 3) {
                Text("MONTHLY RECAP").font(.system(size: 11, weight: .semibold)).kerning(1.3).foregroundStyle(p.muted)
                Text(SmartRule.monthName(month.month)).font(.system(size: 24, weight: .bold)).foregroundStyle(p.text)
                Text(String(month.year)).font(.system(size: 13, weight: .medium)).foregroundStyle(p.muted)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var coverThumb: some View {
        Group {
            if let d = recap.items.first?.artworkData, let img = NSImage(data: d) {
                Image(nsImage: img).resizable().scaledToFill()
            } else if let u = recap.items.first?.artworkURL {
                CachedRemoteImage(url: u) { Rectangle().fill(p.glassFill) }
            } else {
                Rectangle().fill(p.glassFill)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat("Tracks", "\(tracks)"); Spacer(); stat("Minutes", "\(minutes)"); Spacer(); stat("Albums", "\(recap.albumCount)")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 26, weight: .bold)).foregroundStyle(p.text)
            Text(label).font(.system(size: 12)).foregroundStyle(p.muted)
        }
    }

    private var mostPlayed: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Most played").font(.system(size: 13)).foregroundStyle(p.muted)
            VStack(spacing: 14) {
                ForEach(Array(recap.top(4).enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(p.muted).frame(width: 16, alignment: .leading)
                        Text(item.title).font(.system(size: 14, weight: .medium)).foregroundStyle(p.text).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 10)
                        Text(item.plays == 1 ? "1 play" : "\(item.plays) plays").font(.system(size: 13)).foregroundStyle(p.muted)
                    }
                }
            }
        }
    }
}
