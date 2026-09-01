import SwiftUI
import AppKit

/// Circular avatar cropper: drag to reposition, pinch/scroll or the slider to zoom.
/// Output is WYSIWYG — the same transformed view is rendered to a square PNG.
struct ProfileCropSheet: View {
    let image: NSImage
    /// Square preview (playlist cover) instead of the default circular avatar mask.
    var square: Bool = false
    var title: String = "Position your photo"
    var onCancel: () -> Void
    var onCrop: (Data) -> Void
    @Environment(\.palette) private var p

    @State private var scale: CGFloat = 1
    @GestureState private var magnify: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private let viewport: CGFloat = 280
    private let output: CGFloat = 512

    private var maskShape: AnyShape {
        square ? AnyShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)) : AnyShape(Circle())
    }

    private var liveScale: CGFloat { max(1, min(4, scale * magnify)) }
    private var liveOffset: CGSize {
        CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
    }

    /// The image with the current zoom/pan applied — shared by preview and render.
    private var transformed: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: viewport, height: viewport)
            .scaleEffect(liveScale)
            .offset(liveOffset)
    }

    var body: some View {
        VStack(spacing: Space.s5) {
            Text(title)
                .font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)

            ZStack {
                transformed
                    .frame(width: viewport, height: viewport)
                    .clipShape(maskShape)
                maskShape.stroke(p.edge, lineWidth: 1).frame(width: viewport, height: viewport)
            }
            .background(maskShape.fill(p.glassFill).frame(width: viewport, height: viewport))
            .gesture(
                DragGesture()
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in offset.width += v.translation.width; offset.height += v.translation.height }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($magnify) { v, s, _ in s = v }
                    .onEnded { v in scale = max(1, min(4, scale * v)) }
            )

            HStack(spacing: Space.s3) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(p.muted)
                Slider(value: $scale, in: 1...4)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(p.muted)
            }
            .frame(width: viewport)

            Text("Drag to reposition · pinch or use the slider to zoom")
                .font(.system(size: 11)).foregroundStyle(p.muted2)

            HStack(spacing: Space.s3) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.soft)
                    .foregroundStyle(p.muted)
                Button { crop() } label: {
                    Text("Use photo").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(p.accentInk)
                        .padding(.vertical, 9).padding(.horizontal, Space.s5)
                        .background(Capsule().fill(p.accent))
                }.buttonStyle(.soft)
            }
        }
        .padding(Space.s7)
        .frame(width: 380)
        .background(p.page)
    }

    @MainActor
    private func crop() {
        let content = transformed
            .frame(width: viewport, height: viewport)
            .clipShape(Rectangle())          // square output; displayed masked to a circle
            .environment(\.palette, p)
        let renderer = ImageRenderer(content: content)
        renderer.scale = output / viewport
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        onCrop(png)
    }
}
