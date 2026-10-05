import SwiftUI
import AppKit
import CoreImage

/// Pulls a single representative colour out of cover art, used to tint the app's
/// ambient background glow to whatever's playing. Kept deliberately muted/legible so
/// it reads as a soft wash behind the glass rather than a loud fill.
/// Carries an (immutable) `CGImage` across an actor boundary so colour extraction can run off
/// the main thread. `CGImage` is immutable and safe to read concurrently.
struct CGImageBox: @unchecked Sendable { let image: CGImage; init(_ i: CGImage) { image = i } }

enum AmbientColor {
    // One reused GPU context — extraction only runs on track changes, but building a
    // CIContext per call is wasteful.
    private static let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    static func extract(from cg: CGImage) -> Color? {
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])?.outputImage else { return nil }

        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)

        let (r, g, b) = legible(Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// A small palette of the cover's most representative colours (darkest → brightest), for the
    /// bespoke grain-gradient background. Downscales the art and picks vivid, hue-distinct swatches.
    static func palette(from cg: CGImage, count: Int = 3) -> [Color] {
        let n = 24
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let c = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8,
                                bytesPerRow: n * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))

        struct Swatch { let h, s, v: CGFloat }
        var swatches: [Swatch] = []
        for i in stride(from: 0, to: buf.count, by: 4) {
            guard let col = NSColor(srgbRed: CGFloat(buf[i]) / 255, green: CGFloat(buf[i+1]) / 255,
                                    blue: CGFloat(buf[i+2]) / 255, alpha: 1).usingColorSpace(.deviceRGB)
            else { continue }
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            col.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            swatches.append(Swatch(h: h, s: s, v: v))
        }
        // Prefer vivid pixels (saturation × brightness); dedupe by hue so the ramp has variety.
        let ranked = swatches.sorted { ($0.s * $0.v) > ($1.s * $1.v) }
        var picked: [Swatch] = []
        for sw in ranked {
            if picked.allSatisfy({ abs($0.h - sw.h) > 0.06 || abs($0.v - sw.v) > 0.2 }) {
                picked.append(sw)
            }
            if picked.count >= count { break }
        }
        if picked.isEmpty { return [] }
        // Boost so muted covers still read; order darkest → brightest for the ramp.
        return picked
            .map { sw -> (Color, CGFloat) in
                let s = min(1, max(0.45, sw.s * 1.4))
                let v = min(0.9, max(0.35, sw.v * 1.1))
                guard let ns = NSColor(hue: sw.h, saturation: s, brightness: v, alpha: 1).usingColorSpace(.deviceRGB) else {
                    return (Color(hue: Double(sw.h), saturation: Double(s), brightness: Double(v)), v)
                }
                return (Color(.sRGB, red: Double(ns.redComponent), green: Double(ns.greenComponent),
                              blue: Double(ns.blueComponent), opacity: 1), v)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Boost the saturation and pin the brightness into a mid band so even a near-black
    /// or near-white cover produces a colour that shows on the (usually dark) background.
    private static func legible(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        guard let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1).usingColorSpace(.deviceRGB) else {
            return (r, g, b)
        }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        s = min(1, max(0.4, s * 1.35))
        v = min(0.72, max(0.5, v))
        guard let out = NSColor(hue: h, saturation: s, brightness: v, alpha: 1).usingColorSpace(.deviceRGB) else {
            return (r, g, b)
        }
        return (Double(out.redComponent), Double(out.greenComponent), Double(out.blueComponent))
    }
}

/// The ONE ambient background, shared by the main window, Now Playing and Art mode so they
/// always match: the playing album's bespoke skin when it has one, else the page with the
/// cover-tinted glow (two soft blobs + a faint wash), else neutral blobs. Each screen used to
/// build its own (different glow strengths, a blurred-cover layer, different skin scrims), so
/// the same album looked different on every screen.
struct AmbientBackground: View {
    @EnvironmentObject var state: AppState
    @AppStorage("ambientTheming") private var ambientTheming = true
    /// The album whose skin / colour drives the background (the now-playing one).
    var album: Album?
    var palette: Palette
    /// False on screens that want one flat page (the Recap): no tint, blobs or skin.
    var themed: Bool = true
    /// The glow colour; defaults to the now-playing cover's. First Listen passes its own album's
    /// (same extraction), since its album may not be the one playing yet.
    var tint: Color? = nil

    var body: some View {
        let p = palette
        let on = ambientTheming && themed
        let ambient = on ? (tint ?? state.ambient) : nil
        if on && AlbumTheme.hasBackground(album) {
            ZStack {
                AlbumTheme.background(for: album, colors: state.ambientPalette)
                p.page.opacity(0.22)   // the same light scrim on every screen
            }
            .ignoresSafeArea()
        } else {
            ZStack {
                p.page.ignoresSafeArea()
                // A full-bleed wash so the tint reads. Kept low (0.08): content sits directly on
                // this, and a heavier wash pulls muted text under the WCAG AA contrast floor.
                if let ambient {
                    ambient.opacity(0.08).blendMode(.plusLighter).ignoresSafeArea()
                }
                // Blobs as overlays on a flexible Color.clear so their fixed sizes never drive the
                // container's minimum size (which center-clipped the header at small heights).
                if themed {
                    Color.clear
                        .overlay {
                            Circle().fill(ambient?.opacity(0.38) ?? p.blob1).frame(width: 640, height: 640)
                                .blur(radius: 110).offset(x: -200, y: -360)
                        }
                        .overlay {
                            Circle().fill(ambient?.opacity(0.18) ?? p.blob2).frame(width: 560, height: 560)
                                .blur(radius: 110).offset(x: 420, y: 380)
                        }
                        .ignoresSafeArea()
                }
            }
        }
    }
}
