import SwiftUI

/// How the Now Playing screen draws its hero disc.
enum NowPlayingStyle: String, CaseIterable, Identifiable {
    case flat, turntable
    var id: String { rawValue }
    var label: String {
        switch self {
        case .flat:      "Flat disc"
        case .turntable: "Turntable"
        }
    }
    var blurb: String {
        switch self {
        case .flat:      "A clean spinning cover"
        case .turntable: "Record on a platter, with a progress ring"
        }
    }
}

/// A pivoted tracking tonearm drawn over the record, using real turntable geometry (9″ arm on a
/// 12″ LP): pivot-to-spindle ≈ 1.39·R, effective length ≈ 1.51·R, so the stylus sweeps ~23° from
/// the lead-in groove (0.95·R) to the run-out (0.40·R). `progress` (0…1) maps onto that sweep, so
/// the arm's position *is* the playback progress. When paused it cues up a touch (lifts off the
/// groove); the whole thing eases with a spring so play/pause reads as a real cue-down / lift.
///
/// Purely decorative — mount it with `.allowsHitTesting(false)` so the disc's jog-scrub still wins.
struct TonearmView: View {
    /// Radius of the record in points (half the disc's on-screen size).
    var discRadius: CGFloat
    var progress: Double
    var playing: Bool
    var reduceMotion: Bool

    // Geometry, in units of the record radius R (see doc comment).
    private let dPivot = 1.39          // pivot-to-spindle distance
    private let armLen = 1.51          // effective length (pivot → stylus)
    private let rOut = 0.95            // lead-in groove (outer)
    private let rIn = 0.40             // run-out groove (inner, at the label edge)
    private let pivotAngle = -50.0 * .pi / 180   // bearing of the pivot from the spindle (up-right)
    private let cartOffset = 22.0 * .pi / 180    // headshell offset angle (the cartridge's toe-in)

    /// Angle at the pivot (between pivot→spindle and pivot→stylus) that lands the tip at radius `r`.
    private func beta(_ r: Double) -> Double {
        acos((dPivot * dPivot + armLen * armLen - r * r) / (2 * dPivot * armLen))
    }

    var body: some View {
        GeometryReader { geo in
            let R = discRadius
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let lifted = !playing

            let bOut = beta(rOut), bIn = beta(rIn)
            // Cue-up lifts the stylus a few degrees off the current groove (outward).
            let lift = lifted ? 3.0 * .pi / 180 : 0
            let b = bOut + (bIn - bOut) * progress + lift
            let toCentre = pivotAngle + .pi
            let armAngle = toCentre - b

            let pivot = CGPoint(x: c.x + CGFloat(dPivot * cos(pivotAngle)) * R,
                                y: c.y + CGFloat(dPivot * sin(pivotAngle)) * R)
            let tip = CGPoint(x: pivot.x + CGFloat(armLen * cos(armAngle)) * R,
                              y: pivot.y + CGFloat(armLen * sin(armAngle)) * R)
            // Counterweight sits behind the pivot, opposite the armtube.
            let cw = CGPoint(x: pivot.x - CGFloat(0.30 * cos(armAngle)) * R,
                             y: pivot.y - CGFloat(0.30 * sin(armAngle)) * R)
            // Headshell/cartridge: a short stub bent off the tube by the offset angle.
            let headAngle = armAngle + cartOffset
            let head = CGPoint(x: tip.x + CGFloat(0.10 * cos(headAngle)) * R,
                               y: tip.y + CGFloat(0.10 * sin(headAngle)) * R)

            let tube = max(3, 0.026 * R)
            let metal = LinearGradient(colors: [Color(white: 0.82), Color(white: 0.52), Color(white: 0.66)],
                                       startPoint: .top, endPoint: .bottom)
            let darkMetal = LinearGradient(colors: [Color(white: 0.34), Color(white: 0.14)],
                                           startPoint: .top, endPoint: .bottom)

            ZStack {
                // Mounting base plate, behind everything.
                RoundedRectangle(cornerRadius: 0.05 * R, style: .continuous)
                    .fill(darkMetal)
                    .frame(width: 0.24 * R, height: 0.20 * R)
                    .overlay(RoundedRectangle(cornerRadius: 0.05 * R, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .position(pivot)

                // Counterweight behind the pivot.
                bar(from: pivot, to: cw, width: tube * 1.15, fill: darkMetal)
                Circle().fill(darkMetal)
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .frame(width: 0.15 * R, height: 0.15 * R)
                    .position(cw)

                // S-curved armtube, with a hairline specular highlight on top.
                sTube(from: pivot, to: tip, R: R)
                    .stroke(metal, style: StrokeStyle(lineWidth: tube, lineCap: .round))
                sTube(from: pivot, to: tip, R: R)
                    .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: max(1, tube * 0.22), lineCap: .round))
                    .offset(y: -tube * 0.28)

                // Headshell + cartridge at the business end, angled by the offset.
                bar(from: tip, to: head, width: tube * 1.9, fill: darkMetal)
                // Finger-lift tab off the headshell.
                bar(from: tip,
                    to: CGPoint(x: tip.x + CGFloat(0.05 * cos(armAngle - .pi / 2)) * R,
                                y: tip.y + CGFloat(0.05 * sin(armAngle - .pi / 2)) * R),
                    width: max(2, tube * 0.5), fill: metal)
                // Stylus contact point.
                Circle().fill(Color(white: 0.92))
                    .frame(width: max(2, 0.02 * R), height: max(2, 0.02 * R))
                    .position(head)

                // Pivot gimbal.
                Circle().fill(metal)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .overlay(Circle().fill(Color(white: 0.25)).frame(width: 0.035 * R, height: 0.035 * R))
                    .frame(width: 0.11 * R, height: 0.11 * R)
                    .position(pivot)
            }
            // The lift reads as the whole arm rising: a longer, softer shadow when cued up.
            .shadow(color: .black.opacity(lifted ? 0.5 : 0.35),
                    radius: lifted ? 9 : 4, x: 0, y: lifted ? 7 : 3)
            // No per-frame tween on progress: over a whole track the arm sweeps ~23°, i.e. a
            // few hundredths of a degree per 0.2 s update — imperceptible stepping, and it means
            // the arm redraws ~5×/s instead of animating at 60 fps. Only the cue lift springs.
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.72), value: lifted)
        }
    }

    /// A gently S-curved path from pivot to stylus — the classic tonearm silhouette. Two cubic
    /// control points bowed to opposite sides of the straight line give the shallow S.
    private func sTube(from a: CGPoint, to b: CGPoint, R: CGFloat) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        // Unit perpendicular to the arm.
        let px = -dy / max(len, 1), py = dx / max(len, 1)
        let e = 0.05 * R                       // bow depth
        let c1 = CGPoint(x: a.x + dx * 0.34 + px * e, y: a.y + dy * 0.34 + py * e)
        let c2 = CGPoint(x: a.x + dx * 0.66 - px * e, y: a.y + dy * 0.66 - py * e)
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: c1, control2: c2)
        return path
    }

    /// A capsule spanning two points — the primitive every arm segment is built from.
    private func bar(from a: CGPoint, to b: CGPoint, width: CGFloat, fill: LinearGradient) -> some View {
        let len = hypot(b.x - a.x, b.y - a.y)
        let ang = atan2(b.y - a.y, b.x - a.x)
        return Capsule(style: .continuous)
            .fill(fill)
            .frame(width: len, height: width)
            .rotationEffect(.radians(ang))
            .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

/// The static, rotationally-symmetric face of a record: groove rings, play-count wear and the
/// crackle scatter, flattened once into a Metal texture (`drawingGroup`). Conforms to `Equatable`
/// on its only real inputs (`size`, `wear`) so SwiftUI short-circuits it when the owning screen
/// re-renders for an unrelated reason — e.g. the Now Playing progress tick — instead of
/// re-rasterising the gradient + 16 rings + two Canvases each time.
struct RecordArt: View, Equatable {
    var size: CGFloat
    var wear: Double

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.12), .black],
                                         center: .center, startRadius: size * 0.05, endRadius: size / 2))
            ForEach(0..<16) { i in
                Circle().strokeBorder(.white.opacity(0.05), lineWidth: 0.7)
                    .padding(size * 0.03 + CGFloat(i) * size * 0.028)
            }
            VinylPatina(wear: wear).clipShape(Circle())
            VinylCrackle(wear: wear).clipShape(Circle())
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .drawingGroup()
    }

    nonisolated static func == (l: RecordArt, r: RecordArt) -> Bool { l.size == r.size && l.wear == r.wear }
}

/// Analog "warmth" laid over a record: a warm rim vignette plus a sparse scatter of bright dust
/// pops — the visual side of surface crackle. Deterministic and static (cheap, and safe under
/// Reduce Motion). Intensity rides the play-count `wear`, on top of a faint always-on base so a
/// pristine record still looks like vinyl, not glass. Layer it clipped to the disc so it spins.
struct VinylCrackle: View {
    /// 0…1, from `VinylPatina.wear(forCount:)`.
    var wear: Double

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let amount = 0.25 + 0.75 * wear     // base warmth even when mint
            ZStack {
                // Warm brown-amber vignette toward the rim — the "played-in" glow.
                Circle().fill(
                    RadialGradient(colors: [.clear, Color(red: 0.45, green: 0.30, blue: 0.16).opacity(0.10 * amount)],
                                   center: .center, startRadius: s * 0.16, endRadius: s * 0.5)
                )
                .blendMode(.softLight)

                // Dust pops: tiny bright specks scattered over the grooves.
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = s / 2
                    let n = Int(40 + amount * 90)
                    for i in 0..<n {
                        let rad = r * (0.30 + 0.66 * rnd(i, 1))
                        let a = rnd(i, 2) * 2 * .pi
                        let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
                        let d = 0.4 + 1.1 * rnd(i, 3)
                        let op = (0.05 + 0.14 * amount) * (0.4 + 0.6 * rnd(i, 4))
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x, y: pt.y, width: d, height: d)),
                                 with: .color(.white.opacity(op)))
                    }
                }
                .blendMode(.plusLighter)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    /// Cheap deterministic hash → 0…1, so the crackle is stable frame-to-frame.
    private func rnd(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43_758.5453
        return x - floor(x)
    }
}
