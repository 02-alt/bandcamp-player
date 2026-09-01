import SwiftUI

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

    static func remote(_ url: URL) -> NSImage? { cache.object(forKey: url.absoluteString as NSString) }
    static func store(_ img: NSImage, for url: URL) { cache.setObject(img, forKey: url.absoluteString as NSString) }
}

/// Remote image that caches the decoded result, so reused cells show instantly
/// and don't re-decode on scroll (unlike `AsyncImage`).
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
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
        if let hit = ArtworkCache.remote(url) { image = hit; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return }
        ArtworkCache.store(img, for: url)
        image = img
    }
}
