import SwiftUI
import AppKit
import CoreImage

/// Pulls a single representative colour out of cover art, used to tint the app's
/// ambient background glow to whatever's playing. Kept deliberately muted/legible so
/// it reads as a soft wash behind the glass rather than a loud fill.
enum AmbientColor {
    // One reused GPU context — extraction only runs on track changes, but building a
    // CIContext per call is wasteful.
    private static let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    static func extract(from image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
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
    static func palette(from image: NSImage, count: Int = 3) -> [Color] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
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
