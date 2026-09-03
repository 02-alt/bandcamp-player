# Yoin — Apple fluid-interface audit

Audited the full SwiftUI UI against the `apple-design` skill (Apple's *Designing Fluid Interfaces* principles, translated to SwiftUI). Section numbers (§) refer to the skill.

## What's already strong (don't undo)
- Shared spring vocabulary `Motion` (press/hover/glide/lift) and one pressable style `SoftButtonStyle`/`.soft` that gives feedback on **press-down** via `configuration.isPressed` (§1, §10).
- `GlassSurface`/`.glass()` material token with a `reduceTransparency` opaque fallback and top-lit rim (§12).
- Size-specific tracking is correct app-wide: negative kerning on large titles, positive on small caps (§15).
- Clock-driven (`TimelineView`) spinning discs; `matchedGeometry` cover lightbox; the sample-accurate scratch engine.
- `OrbLoader`, `OceanWaveBackground`, `LiquidChromeBackground` already gate on `accessibilityReduceMotion`.

---

## Systemic fixes (do these first — each erases a whole class of per-view findings)

### S1 — Add a typography token layer + adopt Dynamic Type (§15, §6 Flexibility) — HIGH
Every glyph is a hardcoded `.font(.system(size:))`; there's a `Space`/`Radius` scale but no `Type` scale. Nothing scales to the user's text-size setting, and fixed-point frames clip under large text (Settings fields, IPod/WhatsNew/Credits sheet canvases). Add a `Type` enum of semantic styles (`.body`/`.headline`/`.title2`, `relativeTo:` for custom sizes); use `@ScaledMetric` for hero sizes (crate card, 220px cover); make sheets `minWidth/idealWidth` + scroll, not fixed `width×height`. (ShareCard is correctly exempt — fixed 1080×1350 PNG.)

### S2 — Bake the accessibility signals into the theme/motion layer (§14) — HIGH
Reduce Motion is honored only in the bespoke backgrounds; `Motion`/`SoftButtonStyle` ignore it, and `accessibilityContrast` is wired nowhere. Give `SoftButtonStyle`/`HoverHighlight` a reduced-motion variant (swap spring for short ease, drop overshoot); add a high-contrast branch to `Palette`/`GlassSurface` (near-solid fill + defined border). Fixes every button and panel at once.

### S3 — Route scattered easing literals through `Motion`, mirror reversible pairs (§4, §7) — MEDIUM
Many call sites reinvent `.easeInOut(duration: 0.2)`/`.linear` for discrete state changes the app otherwise springs. Menu present (spring) vs dismiss (easeOut 0.12) is **asymmetric** (§7). Add tokens (`menuPresent`/`menuDismiss` mirrored pair, `ambient`, `scheme`) and adopt them. Offenders: ContextMenu 134-137/416/505/516; YoinApp 280/283/338/394/421/434/1152; SettingsView 439/113/151; IPodView 68/87/211; StatsView 16; WishlistView 72; RadioView 142/227.

### S4 — Add haptics on genuine commits (§13) — MEDIUM
`NSHapticFeedbackManager` is used nowhere. Add `.perform(.alignment/.levelChange)` on: hold-to-confirm delete completion, iPod sync drop landing, DJ-fader center detent snap, drag-to-dismiss/collapse commit, like/unlike. Fire on the causal frame only (trackpad-only, so keep to real commits).

---

## Per-cluster findings

### Players & motion
- **HIGH — Jog wheel hard-stops on release** (NowPlayingView.swift:265-276). Tracks 1:1 (§2 good) but `.onEnded` kills all angular momentum. Read `v.velocity`, project landing with the decay fn (`current + (v/1000)·d/(1−d)`, d≈0.998), coast on an under-damped spring while feeding `scrub`/`scratch`. §5/§6.
- **HIGH — Waveform seek fires only on release** (PlayerBar.swift:280-284). `.onEnded` → `.onChanged` for continuous feedback, matching every other scrubber. §1/§10.
- **HIGH — Mini-player transport buttons have no press feedback** (MiniPlayerView.swift:123-187, VinylMiniPlayerView.swift:182-306). `.buttonStyle(.plain)` → the app's `.soft` (or a press-scale style). §1.
- **MED — Drag-to-dismiss commits on position not velocity** (NowPlayingView.swift:151-158). Use `predictedEndTranslation`/`velocity`, not a 120px gate; hand release velocity into the spring. §5/§6.
- **MED — Thumbed sliders teleport to pointer on grab** (NowPlayingView.swift:335-342/304-322, VinylMiniPlayerView.swift:147-165). Capture `grabOffset` when the grab starts on the thumb. §2.
- **MED — Progress ring/bar steps at 0.2s** (NowPlayingView.swift:98-100). `.animation(.linear(0.2), value: player.progress)`. §11.
- **MED — Animated album background not gated on reduce-motion** (NowPlayingView.swift:165, ArtModeView.swift:99). Pass `reduceMotion` into `AlbumTheme.background`. §14.
- **LOW** — PlayerBar vinyl uses `repeatForever(.linear)` + empty-`withAnimation` stop hack (193-200); port to the `TimelineView` clock the other two vinyls use. Upward over-drag hard-clamps at 0 (rubber-band instead, §9).

### Navigation & main views
- **HIGH — Crate drag isn't 1:1, drops all flick velocity** (CrateView.swift:99-124). The signature physical object quantizes translation into 55px steps and `.onEnded` throws away velocity. Track a continuous fractional offset (covers slide with the finger); on release use `predictedEndTranslation`/`velocity` to project a landing index and spring to it. §2/§5/§6. **Highest-leverage single fix.**
- **MED — Album open is origin-less and sometimes a hard cut** (MainPanel.swift:25 vs GridView.swift:162 / CrateView.swift:90). Tap sites don't wrap the state change in `withAnimation`, so the `.opacity` transition doesn't play (context-menu path does — inconsistent). Wrap in `withAnimation(Motion.glide)` + `matchedGeometryEffect` so it expands from the tapped cover. §7/§1.
- **MED — Queue drawer: fixed easing, not interruptible/drag-dismissable, invisible scrim** (QueueView.swift, RootView.swift:64, PlayerBar.swift:111). Spring-drive it, add a 1:1 drag-to-dismiss with rubber-band, raise scrim from `0.001` to ~0.3. §2/§4/§12.
- **MED — Bare `.onTapGesture` targets give no press feedback** (CrateView.swift:88, AlbumDetailView.swift:55/167). Convert to `Button`+`.soft`, layer drag via `.simultaneousGesture`. §1/§10.
- **LOW** — grid content swap on filter/sort change isn't animated (GridView); album-detail hard 1px divider vs scroll-edge fade (§12); search open is an origin-less fixed cross-fade.

### Feature views
- **HIGH — Launch progress bar loops with no reduce-motion path** (LaunchLoadingView.swift:62-68) — a `repeatForever` sweep on the first screen. Static pulsing segment under Reduce Motion. §14.
- **HIGH — iPod bulk "Remove" deletes device files with no confirm/undo** (IPodView.swift:300-329) — while the single-album path uses `holdToConfirm`. Give the bulk path the same guard. §16 Agency.
- **MED — Ungated hover lifts** (WishlistView.swift:119, IPodView.swift:520) — copy the reduce-motion gate that `SyncTile` (IPodView.swift:415) already uses. §14.
- **MED — Recap cover scale 1.22 + Stats 180° 3D flip, no reduced path** (RecapView.swift:89-98, StatsView.swift:195-201). Drop scale to ~1.05 / cross-fade instead of 3D rotation under Reduce Motion. §14.
- **LOW** — iPod album sheet is a centered modal not anchored to the tapped tile (§7); Settings header has no scroll-edge fade (§12); floating selection bar / sheets use a flat translucent Color rather than a real `Material` (§12).

### Design-system foundations (see S1–S4 above; plus)
- **LOW** — `Motion.press` damping 0.6 is bouncier than a non-momentum press wants (~0.8/1.0). `Radius` scale bypassed by literal corner radii (Components/ContextMenu). `MenuRow` reimplements `hoverHighlight()` inline. `LiquidChromeBackground` overlays `.ultraThinMaterial` under the glass panels — risks light-material stacking (§12); use a solid/gradient veil instead.

---

## Suggested order
1. S1 typography/Dynamic Type + S2 accessibility env hooks (biggest reach, mostly foundational).
2. Crate continuous drag + jog-wheel momentum + waveform continuous seek (the three hero-interaction misses).
3. Mini-player press feedback; launch-screen + hover + recap/stats reduce-motion paths.
4. iPod bulk-delete confirmation (safety).
5. S3 motion-token cleanup + S4 haptics (consistency/craft polish).
