import SwiftUI

/// Window-size landmarks and the shared size classes every screen designs against.
///
/// Screens don't scale with the window. Chrome (text, buttons, the scrubber) keeps one fixed size;
/// content reflows (grids add columns, margins grow); hero art steps between a few fixed sizes.
/// A layout only changes when the window crosses a size-class boundary — the same boundary on
/// every screen — so resizing feels solid, like Music or Finder.
///
///   980×600    minimum (Apple Music's floor) — everything must fit, nothing clips
///   1180×780   first-launch default (fits a 13" MacBook Air with the Dock showing)
///   1470×900   a laptop window filling the screen
///   2240×1260  big desktop (24" iMac / 27" Studio Display)
enum WindowSize {
    static let minimum = CGSize(width: 980, height: 600)
    static let ideal = CGSize(width: 1180, height: 780)
    static let laptop = CGSize(width: 1470, height: 900)
    static let desktop = CGSize(width: 2240, height: 1260)
    /// The unified toolbar's title strip. SwiftUI's `.frame(minHeight:)` on the root view measures
    /// the area *below* it, so the root's content floor is the window floor minus this strip
    /// (otherwise a 600pt floor becomes a 652pt window).
    static let titlebarHeight: CGFloat = 52
}

/// Which landmark the window has reached: a window is in the band of the largest landmark it fully
/// contains (both width and height). Screens can differ per band; nothing scales within one.
enum SizeBand: Int, Comparable {
    case small      // below 1180×780
    case standard   // 1180×780 up to 1470×900
    case laptop     // 1470×900 up to 2240×1260
    case desktop    // 2240×1260 and up

    init(width w: CGFloat, height h: CGFloat) {
        func reaches(_ s: CGSize) -> Bool { w >= s.width && h >= s.height }
        if reaches(WindowSize.desktop) { self = .desktop }
        else if reaches(WindowSize.laptop) { self = .laptop }
        else if reaches(WindowSize.ideal) { self = .standard }
        else { self = .small }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// compact < 1200 ≤ regular ≤ 1600 < wide
enum WidthClass: Int, Comparable {
    case compact, regular, wide

    init(_ width: CGFloat) {
        switch width {
        case ..<1200: self = .compact
        case ...1600: self = .regular
        default:      self = .wide
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// short < 760 ≤ tall
enum HeightClass: Int, Comparable {
    case short, tall

    init(_ height: CGFloat) { self = height < 760 ? .short : .tall }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A page that scrolls up under the title bar dissolves there instead of running into the traffic
/// lights / toolbar items. macOS 26: the system's soft scroll-edge effect (the default `.hard` one
/// reads as a solid bar). Earlier: a hand-made mask that hides content behind the controls and
/// fades it back in below `hiddenHeight`.
struct TopScrollEdge: ViewModifier {
    var hiddenHeight: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content.mask(
                VStack(spacing: 0) {
                    Color.clear.frame(height: hiddenHeight)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Space.s7)
                    Color.black
                }
                .ignoresSafeArea()
            )
        }
    }
}
