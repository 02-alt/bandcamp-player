import SwiftUI

extension URL {
    /// Rewrite a Bandcamp CDN cover URL to a different size code. Covers are stored/synced at
    /// `_16` (700×700) for the grid; `_10` is 1200×1200 and `_0` the original — those are what the
    /// fullscreen hero, art mode and the tap-to-zoom lightbox should show instead of an upscaled
    /// thumbnail. Non-Bandcamp URLs (and anything not matching the `_NN.jpg` suffix) pass through
    /// unchanged, so embedded/local artwork is never touched.
    func bcImageSize(_ code: Int) -> URL {
        guard host == "f4.bcbits.com" else { return self }
        let s = absoluteString
        guard let range = s.range(of: #"_\d+\.jpg$"#, options: .regularExpression) else { return self }
        return URL(string: s.replacingCharacters(in: range, with: "_\(code).jpg")) ?? self
    }

    /// The 1200px Bandcamp cover variant for hero/fullscreen/zoom surfaces.
    var bcHiRes: URL { bcImageSize(10) }
}

/// In-memory cache of decoded cover images, so scrolling the grid doesn't
/// re-decode `Data`/re-download URLs every frame.
enum ArtworkCache {
    // NSCache is internally thread-safe.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        return c
    }()

    /// Decoded embedded artwork, cached by album id + a cheap fingerprint of the bytes,
    /// so replacing an album's cover busts the cache instead of showing the stale image.
    static func image(for id: UUID, data: Data) -> NSImage? {
        let fp = "\(data.count):\(data.first ?? 0):\(data.last ?? 0)"
        let key = "id:\(id.uuidString):\(fp)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// Decoded artwork keyed purely on a cheap fingerprint of the bytes, for callers that have
    /// image `Data` but no stable id (e.g. a playlist's custom cover). Avoids re-decoding on every
    /// render/scroll.
    static func image(data: Data) -> NSImage? {
        let key = "data:\(data.count):\(data.first ?? 0):\(data.last ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    static func remote(_ url: URL) -> NSImage? { cache.object(forKey: url.absoluteString as NSString) }
    static func store(_ img: NSImage, for url: URL) { cache.setObject(img, forKey: url.absoluteString as NSString) }
}

/// Remote image that caches the decoded result, so reused cells show instantly
/// and don't re-decode on scroll (unlike `AsyncImage`).
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    /// Fetch the 1200px Bandcamp variant instead of the 700px thumbnail, seeding from the cached
    /// thumbnail (if any) so the hero/zoom shows instantly and then sharpens — no gradient flash.
    var hiRes: Bool = false
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        let target = hiRes ? url.bcHiRes : url
        // Best already-decoded image, instantly: the exact target if we have it, else the low-res
        // original as a stop-gap while the hi-res fetch below lands.
        if let hit = ArtworkCache.remote(target) { image = hit; return }
        if hiRes, let seed = ArtworkCache.remote(url) { image = seed }
        guard let (data, _) = try? await URLSession.shared.data(from: target),
              let img = NSImage(data: data) else { return }
        ArtworkCache.store(img, for: target)
        image = img
    }
}
