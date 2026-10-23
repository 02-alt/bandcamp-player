import SwiftUI
import CabinCore

/// Picker for bringing back albums the user removed from their Bandcamp collection.
/// Tick the ones to restore (or "Select all"), then Restore re-syncs to pull them in.
struct RestoreRemovedSheet: View {
    var onDone: () -> Void
    @EnvironmentObject var state: AppState
    @Environment(\.palette) private var p

    @State private var selection: Set<String> = []

    private var items: [AppState.HiddenAlbum] { AppState.hiddenBandcampAlbums }
    private var allSelected: Bool { !items.isEmpty && selection.count == items.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore removed albums")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)
                    Text("Pick the albums to bring back into your collection.")
                        .font(.uiCallout).foregroundStyle(p.muted2)
                }
                Spacer()
                Button(allSelected ? "Deselect all" : "Select all") {
                    selection = allSelected ? [] : Set(items.map(\.url))
                }
                .buttonStyle(.soft).foregroundStyle(p.muted)
                .font(.uiCallout.weight(.semibold))
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        rowButton(item)
                        if item.id != items.last?.id { Divider().overlay(p.edgeSoft) }
                    }
                }
            }
            .frame(maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(p.glassFill))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(p.edgeSoft, lineWidth: 1))

            HStack(spacing: Space.s3) {
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(.soft).foregroundStyle(p.muted)
                Button { restore() } label: {
                    Text(selection.isEmpty ? "Restore" : "Restore \(selection.count)")
                        .font(.uiBody.weight(.bold))
                }
                .modifier(GlassButton(prominent: true)).controlSize(.large).disabled(selection.isEmpty)
                .opacity(selection.isEmpty ? 0.5 : 1)
            }
        }
        .padding(Space.s7)
        .frame(width: 440)
        .background(p.page)
    }

    private func rowButton(_ item: AppState.HiddenAlbum) -> some View {
        let on = selection.contains(item.url)
        return Button {
            if on { selection.remove(item.url) } else { selection.insert(item.url) }
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(on ? p.accent : p.muted2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.uiBody.weight(.semibold))
                        .foregroundStyle(p.text).lineLimit(1)
                    if !item.artist.isEmpty {
                        Text(item.artist).font(.uiSubheadline)
                            .foregroundStyle(p.muted).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.vertical, Space.s3).padding(.horizontal, Space.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func restore() {
        state.restoreRemovedBandcamp(urls: selection)
        onDone()
    }
}
