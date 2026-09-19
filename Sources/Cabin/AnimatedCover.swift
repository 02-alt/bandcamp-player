import SwiftUI

/// Apple-Music-style flowing colour backdrop, generated on-device from the album art itself: four
/// blurred, oversaturated copies of the cover are stacked and slowly rotated — the two large ones
/// spin in place, the two small ones also orbit — then the whole composite is blurred into a soft,
/// living gradient. The crisp cover sits on top untouched, so nothing tears or "melts".
///
/// Static single frame under Reduce Motion. Falls back to a flat tint when there's no artwork.
struct FlowingArtBackground: View {
    let image: NSImage?
    let tint: Color
    /// Overall saturation boost — Apple oversaturates the copies to make the gradient pop.
    var saturation: Double = 1.9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Each layer: size as a fraction of the covering square, spin period (s), and — for the two
    // small ones — an orbit radius (fraction of the square) and orbit period. Signs flip direction.
    private struct Layer { let scale: CGFloat; let spin: Double; let orbitR: CGFloat; let orbit: Double }
    private let layers: [Layer] = [
        Layer(scale: 1.25, spin:  46, orbitR: 0.00, orbit: 0),    // largest — spins in place
        Layer(scale: 0.80, spin: -37, orbitR: 0.00, orbit: 0),    // large   — spins in place
        Layer(scale: 0.50, spin:  29, orbitR: 0.16, orbit:  34),  // small   — spins + orbits
        Layer(scale: 0.25, spin: -21, orbitR: 0.26, orbit: -24),  // smallest— spins + orbits
    ]

    var body: some View {
        GeometryReader { geo in
            // Cover the whole area even when it's not square (use the longer edge, with headroom).
            let square = max(geo.size.width, geo.size.height) * 1.25
            Group {
                if reduceMotion {
                    composite(square: square, t: 0)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                        composite(square: square, t: tl.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    @ViewBuilder private func composite(square: CGFloat, t: TimeInterval) -> some View {
        ZStack {
            tint   // shows through where the (transparent-padded) copies don't cover
            ForEach(layers.indices, id: \.self) { i in
                let l = layers[i]
                let spin = Angle.degrees(l.spin == 0 ? 0 : t / l.spin * 360)
                let op = l.orbit == 0 ? 0 : t / l.orbit * 2 * .pi
                let dx = l.orbitR == 0 ? 0 : cos(op) * square * l.orbitR
                let dy = l.orbitR == 0 ? 0 : sin(op) * square * l.orbitR
                tile(side: square * l.scale)
                    .rotationEffect(spin)
                    .offset(x: dx, y: dy)
            }
        }
        .frame(width: square, height: square)
        // One blur pass over the composite (cheaper than blurring every copy) → soft gradient.
        .blur(radius: square * 0.09)
        .saturation(saturation)
        .brightness(-0.04)
        .drawingGroup()          // flatten to a Metal layer so the rotations composite efficiently
    }

    @ViewBuilder private func tile(side: CGFloat) -> some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: side, height: side)
        } else {
            tint.frame(width: side, height: side)
        }
    }
}
