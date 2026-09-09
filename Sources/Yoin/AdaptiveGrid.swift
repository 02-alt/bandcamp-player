import SwiftUI

/// Shared sizing for the cover grids (library / wishlist).
///
/// `GridItem(.adaptive(minimum:))` already reflows the *number* of columns to fit, but with a
/// single fixed minimum a narrow window collapses to one enormous cover (min 170 → a 400pt tile),
/// while a very wide window keeps tiles smaller than they could be. So we tune the minimum tile
/// size and inter-tile spacing to the measured content width: tighter and smaller when cramped,
/// roomy at desk-window sizes. Both grids share this so they stay visually identical.
enum CoverGrid {
    static func columns(for width: CGFloat) -> (columns: [GridItem], spacing: CGFloat) {
        let minTile: CGFloat
        let spacing: CGFloat
        switch width {
        case ..<380:
            // Very narrow (solo-ish / half-screen): keep at least two small covers rather than
            // one giant one, and pull the gaps in so they don't eat the row.
            (minTile, spacing) = (108, Space.s3)
        case ..<620:
            (minTile, spacing) = (140, Space.s4)
        default:
            // Roomy: the original feel.
            (minTile, spacing) = (170, Space.s6)
        }
        return ([GridItem(.adaptive(minimum: minTile), spacing: spacing)], spacing)
    }
}

extension View {
    /// Reports this view's width, de-bounced to meaningful (>0.5pt) changes. Mirrors the
    /// `.background(GeometryReader…)` pattern used elsewhere so it composes inside a ScrollView.
    func measureWidth(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { g in
                Color.clear
                    .onAppear { onChange(g.size.width) }
                    .onChange(of: g.size.width) { _, w in onChange(w) }
            }
        )
    }
}
