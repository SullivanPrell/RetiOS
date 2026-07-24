import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(CoreImage)
import CoreImage.CIFilterBuiltins
#endif

// MARK: - Reticulum Network brand color tokens
//
// These keep the `rns*` names the whole app already calls, but each one now
// resolves to a *system semantic color* so the UI adapts automatically to
// Light/Dark mode, Increase Contrast, and Smart Invert — the native (HIG)
// behavior. The RNS-blue identity is preserved through `accentColor`, which is
// backed by the `AccentColor` asset (it already ships both a light and a dark
// blue variant). Because the tokens are computed, they re-resolve per
// appearance at render time rather than baking in a single dark value.

extension Color {

    // MARK: Canvas / backgrounds (grouped-list semantics)

    static var rnsCanvas: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    /// One step above `rnsCanvas` — message bubbles, compose bars, cards.
    ///
    /// The macOS mapping is **not** `controlBackgroundColor`, which is what it
    /// used to be. On macOS that color is byte-identical to
    /// `windowBackgroundColor` in *both* appearances (0.118 in Dark, 1.000 in
    /// Light), so every surface the app painted was invisible against the page:
    /// received message bubbles had no bubble, and the compose bar was
    /// distinguishable only by its `Divider`. On iOS the equivalent pair genuinely
    /// differs, which is why this only ever showed on the Mac.
    ///
    /// `unemphasizedSelectedContentBackgroundColor` is the semantic "content
    /// that reads as distinct but not active", and it is the one system color
    /// that shifts in the right direction in both appearances — measured at
    /// +15.7% luminance in Dark and −13.7% in Light against the page.
    static var rnsSurface: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        #endif
    }

    /// Two steps above `rnsCanvas` — a neutral chip sitting on a surface.
    ///
    /// macOS has no third semantic step here (`underPageBackgroundColor`, the
    /// previous mapping, is a −37% dark grey in Light — far too heavy for a
    /// badge on a white page), so the step is derived from `rnsSurface` by
    /// nudging it toward the foreground in whichever direction the appearance
    /// calls for.
    static var rnsSurfaceRaised: Color {
        #if canImport(UIKit)
        Color(uiColor: .tertiarySystemGroupedBackground)
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let base = NSColor.unemphasizedSelectedContentBackgroundColor
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return base.blended(withFraction: 0.10, of: isDark ? .white : .black) ?? base
        })
        #endif
    }

    // MARK: Borders

    static var rnsBorder: Color {
        #if canImport(UIKit)
        Color(uiColor: .separator)
        #else
        Color(nsColor: .separatorColor)
        #endif
    }
    static var rnsBorderStrong: Color {
        #if canImport(UIKit)
        Color(uiColor: .opaqueSeparator)
        #else
        Color(nsColor: .gridColor)
        #endif
    }

    // MARK: Text

    static var rnsTextPrimary: Color { .primary }
    static var rnsTextSecondary: Color { .secondary }
    static var rnsTextMuted: Color {
        #if canImport(UIKit)
        Color(uiColor: .tertiaryLabel)
        #else
        Color(nsColor: .tertiaryLabelColor)
        #endif
    }

    // MARK: Accent (RNS blue — from the AccentColor asset, light + dark)

    static var rnsAccent: Color { .accentColor }
    static var rnsAccentBright: Color { .accentColor }

    // MARK: Semantic state (system colors — adapt to appearance & vibrancy)

    static var rnsSuccess: Color { .green }
    static var rnsWarning: Color { .orange }
    static var rnsError: Color { .red }
    static var rnsInfo: Color { .blue }

    // MARK: Private hex initialiser (still used by RNSLogoView's fallback gradient)

    fileprivate init(r: UInt8, g: UInt8, b: UInt8, a: Double = 1) {
        self.init(
            red:   Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: a
        )
    }
}

// MARK: - RNS logo view

/// Displays the official Reticulum Network logo.
///
/// Uses a bundled asset named "RNSLogo" when available (add the PNG from
/// https://reticulum.network/manual/_static/rns_logo_512.png to the asset catalog),
/// otherwise falls back to a system symbol that captures the mesh/network concept.
struct RNSLogoView: View {
    var size: CGFloat = 40

    var body: some View {
        Group {
            if loadBrandImage(named: "RNSLogo") != nil {
                Image("RNSLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                fallbackLogo
            }
        }
        .frame(width: size, height: size)
        // Pure branding — conveys no actionable information to VoiceOver.
        .accessibilityHidden(true)
    }

    private var fallbackLogo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.rnsAccent, Color(r: 0x0D, g: 0x5C, b: 0xAA)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "hexagon.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.15))
                .padding(size * 0.1)
            Image(systemName: "network")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(size * 0.22)
        }
    }
}

// MARK: - Convenience modifier: Reticulum accent tint

extension View {
    /// Applies the Reticulum brand accent to this view tree.
    ///
    /// The app no longer forces an appearance — `UIUserInterfaceStyle` was
    /// removed from Info.plist so RetiOS follows the user's system Light/Dark
    /// setting (the HIG-native behavior). `preferredColorScheme` is deliberately
    /// not used, so accessibility overrides (Smart Invert, Increase Contrast)
    /// are respected; all colors resolve through system semantic tokens.
    func rnsTheme() -> some View {
        self
            .tint(Color.accentColor)
    }

    /// No-op. The navigation bar now renders with its native system material
    /// (iOS 26 Liquid Glass), which looks correct in both Light and Dark once
    /// the rest of the UI uses adaptive system colors. Previously this forced a
    /// solid surface fill to stop the bar disappearing against the dark theme —
    /// no longer needed, and fighting the system material is the non-HIG path.
    func rnsNavigationBar() -> some View { self }

    /// Lets `List` / `Form` use their native (grouped) system background instead
    /// of a custom fill — the HIG-native look. A `systemGroupedBackground` page
    /// color is placed *behind* the content so non-scrolling screens (plain
    /// `ScrollView` / `VStack`) still get a proper page color; for a `List`/`Form`
    /// the system's own background draws on top, so this is invisible there.
    ///
    /// Note: `scrollContentBackground(.hidden)` was intentionally removed — that
    /// hide was the root cause of native list styling being suppressed app-wide.
    func rnsScreenBackground() -> some View {
        self.background(Color.rnsCanvas.ignoresSafeArea())
    }

    /// Canvas background for non-scrolling screens (empty states, custom layouts).
    func rnsCanvasBackground() -> some View {
        self.background(Color.rnsCanvas.ignoresSafeArea())
    }

    /// Material for a bar the app draws itself — the NomadNet URL bar, the
    /// sidebar status footer, the compose bars.
    ///
    /// Uses **Liquid Glass** on OSes that have it, falling back to
    /// `.ultraThinMaterial` below that. The app builds against the iOS/macOS 26
    /// SDK and does *not* set `UIDesignRequiresCompatibility`, so system chrome
    /// — toolbars, sidebars, tab bars — already renders as Liquid Glass for
    /// free. This helper is for the surfaces the app draws itself, which the
    /// system cannot restyle on our behalf and which otherwise stay visibly
    /// flat next to the chrome that did update.
    ///
    /// `placement` is new, and it is the reported bug. `glassEffect(_:in:)`
    /// *draws the shape you hand it*, so the old unconditional `.rect` painted
    /// four literal 90° corners at the bar's bounds. Under a top toolbar that is
    /// right — nothing curved is adjacent. Pinned to the bottom of an iPhone it
    /// puts a hard rectangle corner over the display's radius and alongside the
    /// iOS 26 floating capsule tab bar: the "rectangle colliding with a capsule"
    /// in the bug report. The original justification ("a capsule would round its
    /// outer corners away from the window edge") was a macOS-window argument
    /// that had been applied to every platform.
    ///
    /// HIG ▸ Components ▸ Toolbars: "If you need to create a custom component,
    /// ensure that its corner radius is also concentric with the bar's corners."
    /// `ConcentricRectangle` resolves corners "relative to the container shape,
    /// so your view adapts correctly across devices and sizes without
    /// hard-coded values"; a bar pinned to the screen bottom inside a
    /// `NavigationStack` inherits the window's container shape, so no explicit
    /// `containerShape` call is needed here.
    ///
    /// `concentric(minimum:)` rather than a bare `.concentric`, per the same
    /// page: "When your ConcentricRectangle's corners are far away from the
    /// containing shape's corners … the corner radius the system calculates may
    /// be zero." Without the floor, a bar the system decides is too far from the
    /// display corner silently renders square again — i.e. this exact bug
    /// returns with no compile error to catch it.
    ///
    /// Deployment targets are still iOS 17 / macOS 14, so the API must be
    /// runtime-gated; `#available` does not relax the compile-time SDK
    /// requirement, which the CI workflow already selects Xcode for.
    func rnsBarMaterial(_ placement: RNSBarPlacement = .interior) -> some View {
        modifier(RNSBarMaterial(placement: placement))
    }

    /// Anchors an app-drawn bar to the bottom of a scrolling screen.
    ///
    /// `safeAreaBar` — *not* `safeAreaInset` — on iOS/macOS 26. The two are
    /// otherwise identical, and the difference is exactly the missing bottom
    /// fade: `safeAreaBar` extends the edge effect of any scroll views affected
    /// by the inset safe area, while `safeAreaInset` only reserves space. That
    /// is why message bubbles scrolled under the compose bar and behind the
    /// floating tab bar with no transition at all, and why the screen needed a
    /// hand-drawn `Divider()` to fake one. HIG ▸ Foundations ▸ Layout: "Instead
    /// of a background, use a scroll edge effect to provide a transition between
    /// content and the control area."
    @ViewBuilder
    func rnsBottomBar<Bar: View>(spacing: CGFloat? = 0,
                                 @ViewBuilder content: () -> Bar) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.safeAreaBar(edge: .bottom, spacing: spacing, content: content)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: spacing, content: content)
        }
    }

    /// Pins a bottom-anchored scroll view to its newest content.
    ///
    /// Replaces the `ScrollViewReader` + `proxy.scrollTo` dance, which had a
    /// trigger for exactly one of the four cases that need one:
    ///   1. First appearance — `scrollTo` in `onAppear` raced the `LazyVStack`;
    ///      trailing rows are not materialised on the first layout pass, so the
    ///      proxy had no target and the thread opened part-way up.
    ///   2. Keyboard raise — grows the bottom safe area and shrinks the scroll
    ///      view's *container*. SwiftUI keyboard avoidance only guarantees the
    ///      *focused* view stays visible, and the focused view is the TextField
    ///      down in the inset, not the list. No trigger fired.
    ///   3. Compose growth (`lineLimit(1...5)`, up to ~80 pt) — same container
    ///      shrink, same silence.
    ///   4. A new message arriving — the one case that did work.
    ///
    /// The two-argument `defaultScrollAnchor(_:for:)` is the whole reason this is
    /// a helper: the single-argument form ALSO sets the *alignment* role, so
    /// content shorter than the viewport gets pinned to the bottom. But
    /// `ScrollAnchorRole` is iOS 18 / macOS 15 and the app floor is iOS 17 /
    /// macOS 14, so it cannot appear in a signature the floor has to compile.
    /// Below 18 we take the single-argument form, and callers must keep
    /// short-content states out of the scroll view (see `ChannelRoomView`'s
    /// empty state, which is an `.overlay` for exactly this reason).
    @ViewBuilder
    func rnsBottomScrollAnchor() -> some View {
        if #available(iOS 18, macOS 15, *) {
            self.defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
        } else {
            self.defaultScrollAnchor(.bottom)
        }
    }

    /// Hairline + material behind an app-drawn bottom bar, for OSes predating
    /// the scroll edge effect.
    ///
    /// No-op on iOS/macOS 26: `rnsBottomBar` uses `safeAreaBar` there, which
    /// extends the scroll view's edge effect into the bar, and that *is* the
    /// separation — painting a second full-width material on top of it is the
    /// "reduce the use of toolbar backgrounds" case in HIG ▸ Toolbars. Below 26
    /// there is no edge effect at all, and `Color.rnsSurface`'s own note in this
    /// file records that the macOS compose bar was once "distinguishable only by
    /// its `Divider`" — so the hairline is load-bearing there, not decoration.
    @ViewBuilder
    func rnsLegacyBarChrome() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
        } else {
            VStack(spacing: 0) {
                Divider()
                self
            }
        }
    }

    /// No-op. Rows now use the system's native row background, which keeps
    /// correct selection / highlight / swipe-action behavior. The system row
    /// color already matches `rnsSurface` (secondary grouped background), so this
    /// changes nothing visually — it just stops overriding system row chrome.
    func rnsRow() -> some View { self }

    /// No-op on macOS — `navigationBarTitleDisplayMode` only exists on
    /// iOS/iPadOS/tvOS/watchOS (it configures the *navigation bar's* title
    /// size). macOS window title bars have no inline/large display-mode
    /// concept, so there's nothing to apply there.
    ///
    /// Centralizing the `#if os(iOS)` here — rather than at each of the ~20
    /// call sites across the app — is what makes those views compile (and
    /// look right) for the native macOS destination introduced alongside
    /// this helper.
    @ViewBuilder
    func rnsInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Pins a large, left-aligned screen title flush to the top of the content,
    /// with an optional trailing action button. This replaces the system
    /// collapsing large-title nav bar — which reserves an empty ~44 pt inline
    /// bar *above* the big title (the "huge dead space" between the status bar
    /// and the title) — with an in-content title that sits right under the safe
    /// area. Only the content below scrolls; the title stays put.
    ///
    /// iOS: draws the title (and trailing action) in-content and hides the now
    /// empty navigation bar. Pushed destinations still get their own nav bar /
    /// back button, since bar-hiding applies only to this level of the stack.
    ///
    /// macOS: there is no navigation bar to reclaim and a custom in-content
    /// title would duplicate the window-chrome title, so fall back to the
    /// native `navigationTitle` + a trailing window-toolbar item.
    /// Titles a screen that has no trailing action.
    ///
    /// This is a *separate overload* rather than a defaulted `trailing:`
    /// parameter, and that distinction is load-bearing on macOS: a
    /// `ToolbarItem` wrapping an `EmptyView` still claims a toolbar slot, and a
    /// slot the user cannot see is still a slot the system can decide to
    /// collapse. Every Mac screen was rendering a "»" overflow chevron —
    /// hiding real actions behind it — because each one contributed a phantom
    /// primary-action item here. With the default argument gone, screens
    /// without an action contribute nothing at all.
    @ViewBuilder
    func rnsPinnedTitle(_ title: String) -> some View {
        #if os(iOS)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.largeTitle.bold())
                Spacer(minLength: 8)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            self
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .toolbar(.hidden, for: .navigationBar)
        #else
        self.navigationTitle(title)
        #endif
    }

    @ViewBuilder
    func rnsPinnedTitle<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        #if os(iOS)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.largeTitle.bold())
                Spacer(minLength: 8)
                // Size the action like a prominent nav action (≈22 pt) rather
                // than default body text, and tint it with the brand accent.
                trailing()
                    .font(.title2)
                    .tint(Color.rnsAccent)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            self
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .toolbar(.hidden, for: .navigationBar)
        #else
        self
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .primaryAction) { trailing() } }
        #endif
    }

    /// No-op on macOS — `textInputAutocapitalization` is iOS/iPadOS/tvOS/
    /// watchOS only (it configures the on-screen keyboard's shift-key
    /// behavior). macOS text fields have no software keyboard / auto-cap
    /// concept, so suppressing it there is meaningless — and the modifier
    /// doesn't exist on macOS's `View` at all, hence the guard.
    @ViewBuilder
    func rnsNoAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Standard entry styling for a destination-hash `TextField`, so every
    /// hash-entry form in the app behaves identically (monospaced glyphs, no
    /// autocorrect/autocapitalization, ASCII keyboard on iOS, a "Done" submit
    /// key). The live hex-filtering is applied at each call site since it needs
    /// the binding. Centralizing the styling here is the HIG "be consistent"
    /// fix — the four hand-rolled forms previously diverged on keyboard type
    /// and submit label.
    ///
    /// **Prefer `RNSHashField` to calling this directly.** `.font(_:)` is an
    /// *environment* value — font information flows down the view hierarchy as
    /// part of the environment — so the monospaced face set here reaches
    /// everything in the modified view's subtree, *including the field's label*.
    /// That is invisible on iOS, where a form row uses the label as in-field
    /// placeholder text; on macOS a form always hoists the label out to the
    /// leading edge, and it took the monospaced font with it. Tools ▸ Ping
    /// rendered "Destination hash (32 hex chars)" as a monospaced sentence in a
    /// column of its own, beside an empty, hintless field. `RNSHashField` puts
    /// the label outside this subtree entirely, which is a structurally stronger
    /// fix than overriding the font back afterwards.
    @ViewBuilder
    func rnsHashFieldStyle() -> some View {
        let styled = self
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .rnsNoAutocapitalization()
        #if os(iOS)
        styled
            .keyboardType(.asciiCapable)
            .submitLabel(.done)
        #else
        styled
        #endif
    }

    /// Plays a haptic on iOS for a discrete event; no-op on macOS (Macs have no
    /// Taptic Engine in this context). `trigger` is any `Equatable` whose change
    /// signals the event occurred (e.g. a success counter, or a state enum).
    @ViewBuilder
    func rnsFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        #if os(iOS)
        self.sensoryFeedback(feedback, trigger: trigger)
        #else
        self
        #endif
    }

    /// Closure variant: choose the feedback from the old/new trigger values
    /// (e.g. map a call-state transition to success / error). iOS-only.
    @ViewBuilder
    func rnsFeedback<T: Equatable>(trigger: T,
                                   _ feedback: @escaping (T, T) -> SensoryFeedback?) -> some View {
        #if os(iOS)
        self.sensoryFeedback(trigger: trigger, feedback)
        #else
        self
        #endif
    }
}

// MARK: - Bar geometry & layout tokens

/// Where an app-drawn bar sits, which decides what its corners must do.
///
/// A *geometry* distinction, not a styling one. On iOS 26 the display's rounded
/// corner is part of the layout and the tab bar is a floating capsule, so a
/// bar's corner radius has neighbours it must agree with.
enum RNSBarPlacement {
    /// Butted against system chrome inside the window — the NomadNet URL bar
    /// under the toolbar, a sidebar footer inside a Mac window. Square corners
    /// are correct there: nothing curved is adjacent.
    case interior
    /// Pinned to the bottom edge of the screen, above the home indicator and (on
    /// iPhone) beside the floating capsule tab bar. Bottom corners must be
    /// concentric with the display's own radius.
    ///
    /// Requested, not guaranteed — see `RNSBarMaterial`, which downgrades this
    /// to `.interior` wherever the bar is not actually at a screen edge.
    case screenBottom
}

/// Applies `rnsBarMaterial`'s glass, resolving `.screenBottom` against the
/// layout the bar is actually in.
///
/// A `ViewModifier` rather than a plain `View` extension purely so it can read
/// `horizontalSizeClass`, and that read is load-bearing. `.screenBottom` asks
/// for concentric bottom corners with a `.fixed(14)` floor, which is right only
/// when the bar really does sit at the bottom edge of the display. In a
/// `NavigationSplitView` detail column — every Mac window, and iPad at regular
/// width — the bar's bottom-*leading* corner is at the sidebar divider,
/// hundreds of points inboard. The concentric term resolves to zero there and
/// the floor takes over, cutting a 14 pt notch into the bar mid-window and
/// exposing a wedge of the canvas behind it. `uniformBottomCorners` propagates
/// the larger of the two computed radii to *both* corners, so it cannot be
/// dodged per-corner either.
///
/// `sizeClass == .compact` is exactly the condition under which `RootView`
/// chooses `TabRootView` — the full-width, genuinely screen-bottom layout — so
/// this tracks the real geometry rather than guessing from the platform.
/// `horizontalSizeClass` is nil on macOS, which correctly lands on `.interior`.
private struct RNSBarMaterial: ViewModifier {
    let placement: RNSBarPlacement
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isAtScreenEdge: Bool {
        placement == .screenBottom && sizeClass == .compact
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            if isAtScreenEdge {
                content.glassEffect(
                    .regular,
                    in: .rect(uniformTopCorners: .fixed(0),
                              uniformBottomCorners: .concentric(minimum: .fixed(14)))
                )
            } else {
                content.glassEffect(.regular, in: .rect)
            }
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}

/// Shared measures for reading columns.
///
/// A thread and its compose bar use the *same* cap so the bar never spans wider
/// than the content it separates. Without one, `RootView` routes
/// `sizeClass == .regular` to a `NavigationSplitView` whose detail column is
/// ~1000 pt wide, and every message becomes a single 130-character line.
///
/// These are empirical values, not derived from a HIG table — the HIG only says
/// to "restrict the width of text for optimal readability" (Foundations ▸
/// Layout). Worth an eye on an 11" and a 13" iPad.
enum RNSLayout {
    /// Max width of a message thread / reading column.
    static let threadWidth: CGFloat = 720
    /// Max width of one bubble inside `threadWidth` (~78%, which keeps the
    /// inbound/outbound asymmetry legible instead of full-bleed on both sides).
    static let bubbleWidth: CGFloat = 560
}

extension ToolbarItemPlacement {
    /// Trailing toolbar slot that resolves correctly per platform.
    ///
    /// iOS/iPadOS: `.topBarTrailing` — the modern (iOS 16+) name for the
    /// trailing nav-bar slot (`.navigationBarTrailing` is the older spelling
    /// of the exact same placement).
    ///
    /// macOS: there is no navigation bar — `.primaryAction` lands the item
    /// in the window toolbar's primary (trailing-most) slot, the closest
    /// native equivalent.
    static var rnsTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

// MARK: - Destination-hash entry field

/// A destination-hash entry field that reads correctly on *both* platforms.
///
/// Motivated by two macOS-only defects visible together in Tools ▸ Ping: the
/// "placeholder" rendered as a **monospaced label** in a column of its own,
/// while the field beside it stretched ~1000 pt to the window edge containing no
/// hint at all.
///
/// 1. **The placeholder was never a placeholder.** `TextField("Destination
///    hash…", text:)` supplies a *label*. SwiftUI's own "Text field prompts"
///    documentation is explicit: a form on macOS always places the label at the
///    leading edge of the field and uses a prompt, when available, as
///    placeholder text within the field itself — whereas on iOS the field uses
///    either the prompt or the label as placeholder text. A label-only
///    initializer therefore looks correct on iOS and strands the hint outside
///    the field on macOS, in *every* form style. `.formStyle(.grouped)` alone
///    does not fix this half.
///
/// 2. **The monospaced font leaked onto that label.** See `rnsHashFieldStyle()`.
///    Fixed structurally here: on macOS `LabeledContent` owns the visible label,
///    so it is never inside the subtree the monospaced `.font` flows through.
///    There is no `.font(.body)` override to forget.
///
/// `LocalizedStringKey`, not `String`: a `String` parameter would bind
/// `TextField` to its `StringProtocol` overload — the deliberately
/// *non-localized* one — and quietly drop every hash prompt out of the
/// localization table with no compile error. A literal at the call site still
/// converts implicitly.
///
/// `.labelsHidden()` inside the `LabeledContent`: always provide a label for
/// controls even when hiding it, because SwiftUI uses labels for other purposes
/// including accessibility. The label is still declared; `LabeledContent`
/// supplies the visible pairing.
///
/// The call site keeps its own `.onChange` hex filtering, which needs the
/// binding and differs per screen.
struct RNSHashField: View {
    private let label: LocalizedStringKey
    private let prompt: LocalizedStringKey
    /// Written out by hand for iOS, where the label never renders and the prompt
    /// has to carry the whole meaning. Interpolating `"\(label) (\(prompt))"`
    /// instead measures ~345 pt of monospaced `.body` against ~290 pt of usable
    /// row width on an iPhone SE — it truncates the only hint iOS shows.
    private let compactPrompt: LocalizedStringKey
    @Binding private var text: String

    init(_ label: LocalizedStringKey,
         prompt: LocalizedStringKey,
         compactPrompt: LocalizedStringKey,
         text: Binding<String>) {
        self.label = label
        self.prompt = prompt
        self.compactPrompt = compactPrompt
        self._text = text
    }

    var body: some View {
        #if os(macOS)
        // The cap belongs on the *control*, not on the labelled row. A
        // `.frame(maxWidth:)` on the whole `LabeledContent` constrains label and
        // field together: the label eats ~100 pt of the budget and a pasted
        // 32-character hash then clips mid-glyph at ~27 — the field cannot show
        // the one value it exists to hold. Capping the control instead also
        // preserves the trailing-aligned-control alignment every other grouped
        // row in the app has.
        //
        // 340 pt: 32 monospaced `.body` glyphs measure ~255 pt, plus the bezel
        // and caret with headroom. HIG ▸ Text fields: "match the size of a text
        // field to the quantity of anticipated text."
        LabeledContent {
            field
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
        } label: {
            Text(label)
        }
        #else
        field
        #endif
    }

    private var field: some View {
        #if os(macOS)
        TextField(text: $text, prompt: Text(prompt)) { Text(label) }
            .rnsHashFieldStyle()
        #else
        // iOS renders nothing *but* the placeholder, so it gets the written-out
        // compact string rather than label and prompt concatenated.
        TextField(text: $text, prompt: Text(compactPrompt)) { Text(label) }
            .rnsHashFieldStyle()
        #endif
    }
}

// MARK: - Section picker (native segmented control)

/// A thin convenience wrapper over a native segmented `Picker`. Call sites keep
/// passing `[(label, value)]` plus a binding; this renders the standard system
/// segmented control — the HIG-native choice — instead of a custom underline
/// tab bar that had to hand-roll its own colors, animation, and a11y traits.
/// The one matching rule every peer search in the app uses.
///
/// Two things it fixes, both of which were copy-pasted into six filters:
///
/// **Hashes match by PREFIX, not substring.** A destination hash is 32 lowercase
/// hex characters, so `contains("a")` is true for ~87% of all hashes
/// (1 − (15/16)^32) — typing the first letter of a name returned nearly the
/// entire list, with the accidental matches indistinguishable from the real one
/// because the matched region is usually inside the middle that `truncatedHash`
/// hides. Prefix matching is also what Reticulum addressing and every other hash
/// affordance in this app already imply (`PeerEntity.shortHash` is `prefix(8)`).
///
/// **The query is trimmed.** A trailing space — trivially produced by iOS
/// autocorrect or a paste — made every match fail, which reads as "no results"
/// rather than as a typo.
enum RNSSearch {

    /// Normalised query, or `nil` when there is effectively nothing to search
    /// for (empty, or only whitespace). `nil` means "show everything".
    static func query(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when `query` (already normalised) matches this row.
    ///
    /// - Parameters:
    ///   - name: display name, if the row has one.
    ///   - hashes: every address the row can be found by. Matched by prefix.
    static func matches(_ query: String, name: String?, hashes: [String?]) -> Bool {
        if let name, name.lowercased().contains(query) { return true }
        return hashes.contains { $0?.lowercased().hasPrefix(query) == true }
    }

    static func matches(_ query: String, name: String?, hash: String) -> Bool {
        matches(query, name: name, hashes: [hash])
    }
}

/// The field `rnsInlineSearch` stacks above a list. See that modifier for why
/// these screens cannot use `.searchable`.
///
/// `prompt` is a `LocalizedStringKey`, not a `String`, for the same reason
/// `RNSHashField` documents: a `String` parameter binds `TextField` to its
/// deliberately non-localized `StringProtocol` overload and silently drops the
/// prompt out of the localization table. A literal at the call site still
/// converts implicitly.
struct RNSInlineSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.rnsTextSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .rnsNoAutocapitalization()
                .submitLabel(.search)
                .focused($focused)
                .accessibilityLabel(Text(prompt))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.rnsTextMuted)
                        // The glyph is ~17pt. Pad the hit region to the HIG
                        // minimum without growing the field, the same way the
                        // NomadNet URL bar's chevrons do.
                        .frame(minWidth: 44, minHeight: 30)
                        .contentShape(Rectangle())
                }
                // .plain so the glyph does not pick up bordered button chrome
                // inside the field on macOS.
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.rnsSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // The whole capsule focuses the field, not just the ~1pt of text inside
        // it. `.searchable` gives this for free; an app-drawn field does not,
        // and tapping the magnifier or the padding doing nothing reads as broken.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

struct RNSSectionPicker<T: Hashable>: View {
    struct Tab: Identifiable {
        let id: Int
        let label: String
        let value: T
    }

    let tabs: [Tab]
    @Binding var selection: T

    init(_ tabs: [(String, T)], selection: Binding<T>) {
        self.tabs = tabs.enumerated().map { Tab(id: $0.offset, label: $0.element.0, value: $0.element.1) }
        self._selection = selection
    }

    var body: some View {
        Picker("Section", selection: $selection) {
            ForEach(tabs) { tab in
                Text(tab.label).tag(tab.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Container for a settings-style screen — a stack of `Section`s of labelled
/// rows and explanatory footers (Settings, Interfaces).
///
/// **iOS** keeps `List` + `.insetGrouped`. `List` is what supports
/// `swipeActions`, which the Interfaces screen uses to remove an interface, so
/// this is not interchangeable with `Form` there.
///
/// **macOS** uses `Form` + `.formStyle(.grouped)`, which is what a Mac settings
/// pane actually is. `List` gave rows that spanned the whole window: on a
/// 1100 pt-wide window a row read as its label on the far left and its control
/// ~1000 pt away on the far right, with nothing between. Grouped `Form` boxes
/// the sections and constrains their width the way System Settings does.
///
/// It also fixes a genuine defect rather than only a stylistic one: in the
/// `List` layout, section footers were laid out on a single line and truncated
/// — the Interfaces overlay-network footer ended mid-sentence at "Reticulum
/// then…" — because the row was nearly wide enough to fit them. `Form` footers
/// wrap.
@ViewBuilder
func rnsSettingsContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    #if os(macOS)
    Form { content() }
        .formStyle(.grouped)
    #else
    List { content() }
        .listStyle(.insetGrouped)
    #endif
}

extension View {
    /// Style for a *content* list — conversations, peers, paths, channels, logs.
    /// (Settings-style screens use `rnsSettingsContainer` instead.)
    ///
    /// iOS keeps `.plain`, the edge-to-edge phone idiom. macOS uses `.inset`:
    /// `.plain` there draws a full-bleed list with no margins and no row
    /// affordances, which is why the Mac conversation list read as bare text
    /// shoved against the window edge with its timestamp stranded on the far
    /// right.
    @ViewBuilder
    func rnsContentListStyle() -> some View {
        #if os(macOS)
        // Alternating row backgrounds are the Mac idiom for a scannable list of
        // records — Finder's list view, Mail's message list, Xcode's issue
        // navigator. The banding is what separates one row from the next, and
        // the *only* filled row is the selected one.
        //
        // Two earlier attempts were wrong in opposite directions. `.bordered`
        // boxes the whole list, which collides with the grouped `Form` boxes on
        // the settings screens. Giving every row its own rounded card fixed the
        // "unselected row is the same colour as the page" complaint, but it
        // transplanted the iOS inset-grouped idiom onto macOS: a column of
        // heavy grey slabs running edge to edge, which is not what the HIG
        // describes and read worse than the problem it solved.
        self.listStyle(.inset(alternatesRowBackgrounds: true))
        #else
        self.listStyle(.plain)
        #endif
    }

    /// Stacks a search field above a list, for screens where `.searchable`
    /// cannot work.
    ///
    /// **Use `.searchable` when the screen has a navigation bar** — that is the
    /// system control and it is what `DestinationsView`, `InterfaceDirectoryView`
    /// and `LogsView` correctly use.
    ///
    /// This exists for the **tab roots**, which do not have one — and where
    /// `.searchable` fails *silently*:
    ///
    /// - **iOS** — `rnsPinnedTitle` draws the tab's large title itself and calls
    ///   `.toolbar(.hidden, for: .navigationBar)`. Every iOS
    ///   `SearchFieldPlacement` resolves into the navigation bar (`.automatic`
    ///   and `.toolbar` both land in `.navigationBarDrawer`), so with the bar
    ///   hidden there is nowhere for the field to go and nothing renders.
    ///   Apple's own note on `SearchFieldPlacement` — "Depending on the
    ///   containing view hierarchy, SwiftUI might not be able to fulfill your
    ///   request" — is the entire diagnostic: no warning, no field.
    /// - **macOS** — the field *would* render, in the window toolbar, which on
    ///   these screens already carries `rnsSectionPicker`'s principal segmented
    ///   control plus a primary action. A third item is exactly what collapses a
    ///   Mac toolbar into the "»" overflow chevron that `rnsPinnedTitle`'s own
    ///   comment documents fighting.
    ///
    /// So the field is drawn in-content on both platforms — the same
    /// app-drawn-bar idiom as the NomadNet URL bar — which also keeps the three
    /// peer lists looking identical. The *matching semantics* at each call site
    /// should still follow the house pattern: a `filtered` array matching name
    /// or hash case-insensitively, plus a `ContentUnavailableView.search`
    /// overlay applied to the list **before** this modifier, so the no-results
    /// state cannot cover the field and strand the user.
    ///
    /// The `maxWidth/maxHeight: .infinity` on `self` mirrors `rnsSectionPicker`:
    /// without it the list shrinks to its intrinsic height inside the `VStack`
    /// and floats vertically centred.
    func rnsInlineSearch(text: Binding<String>,
                         prompt: LocalizedStringKey = "Name or hash") -> some View {
        VStack(spacing: 0) {
            RNSInlineSearchField(prompt: prompt, text: text)
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Attaches a section switcher to a screen, placed the way each platform
    /// expects.
    ///
    /// **iOS** stretches a segmented control edge-to-edge under the title — the
    /// standard phone idiom, and what this app has always done.
    ///
    /// **macOS** puts it in the window toolbar instead. A Mac segmented control
    /// sizes to its content rather than filling the width, so the iOS placement
    /// rendered as a small pill marooned in the middle of an otherwise empty
    /// row across the top of every pane — the most conspicuous phone-ism in the
    /// Mac build. The toolbar is where Finder, Mail and Xcode put exactly this
    /// control.
    ///
    /// Apply to the *content*; the modifier arranges the picker around it.
    @ViewBuilder
    func rnsSectionPicker<T: Hashable>(_ tabs: [(String, T)], selection: Binding<T>) -> some View {
        #if os(macOS)
        self.toolbar {
            ToolbarItem(placement: .principal) {
                RNSSectionPicker(tabs, selection: selection)
            }
        }
        #else
        VStack(spacing: 0) {
            RNSSectionPicker(tabs, selection: selection)
                .padding(.horizontal)
                .padding(.vertical, 8)
            self
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }
}

// MARK: - Platform-adaptive empty state

/// Full-fill empty state on macOS (no card chrome); ContentUnavailableView on iOS.
///
/// On macOS, ContentUnavailableView renders as a fixed-size rounded card that
/// floats in whatever space is offered — giving an awkward centered-card-on-
/// empty-canvas look. Worse, because that card does *not* expand to fill, a
/// bare `ContentUnavailableView` placed below fixed chrome in a `VStack` (e.g.
/// a URL bar) lets the whole stack shrink to its intrinsic height and get
/// vertically centered by an outer `.frame(maxHeight: .infinity)` — dragging
/// that chrome into the middle of the pane. RNSEmptyState fills the space and
/// centers only its own content, so any sibling chrome stays put.
///
/// Pass `actionTitle` + `action` to add a trailing button (e.g. "Retry" on an
/// error state); omit both for a plain empty state. Both platforms render the
/// button — on iOS via ContentUnavailableView's `actions` builder.
struct RNSEmptyState: View {
    let title: String
    let systemImage: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        #if os(macOS)
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(Color.rnsTextMuted)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.rnsTextPrimary)
            Text(description)
                .font(.callout)
                .foregroundStyle(Color.rnsTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rnsCanvasBackground()
        #else
        if let actionTitle, let action {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            } actions: {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        } else {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
        }
        #endif
    }
}

// MARK: - Status badge (shared pill)

/// A small colored status pill — the shared version of the several hand-rolled
/// capsule badges that had diverged on padding, corner shape, and color model.
/// `color` drives both the text and a faint tinted background.
///
/// The tinted-background model (`color.opacity(0.18)`) only works when `color`
/// is a *saturated* color. For neutral metadata badges the caller should pass
/// `neutral: true`, which uses an opaque `rnsSurfaceRaised` fill with legible
/// secondary text: deriving the fill from a translucent label color (e.g.
/// `tertiaryLabel`) instead multiplies down to ~5% alpha, so the pill vanishes
/// and the text drops below the contrast floor (Labels / Color HIG).
struct RNSBadge: View {
    let text: String
    var color: Color = .rnsAccent
    var monospaced: Bool = false
    var neutral: Bool = false

    var body: some View {
        Text(text)
            .font(monospaced ? .caption2.monospaced().weight(.bold)
                             : .caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(neutral ? Color.rnsSurfaceRaised : color.opacity(0.18), in: Capsule())
            .foregroundStyle(neutral ? Color.rnsTextSecondary : color)
            .lineLimit(1)
    }
}

// MARK: - Peer identity block (shared row content)

/// The shared name + hash + last-seen block used by every peer row (Messages
/// Peers, Destinations, LXST call peers). Unifies three hand-rolled rows that
/// had diverged on the name font (`.headline` vs `.body.weight(.medium)`). When
/// `name` is nil the truncated hash becomes the primary label (no duplicate
/// hash line).
struct PeerIdentityView: View {
    let name: String?
    let hash: String
    var lastSeen: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name ?? hash.truncatedHash)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if name != nil {
                Text(hash.truncatedHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let lastSeen {
                Text(RNSDate.ago(lastSeen))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Timestamps

/// Date formatting for list rows.
///
/// Replaces `Text(date, style: .relative)`, which renders a bare *duration* —
/// a conversation last touched yesterday evening read as "21 hr, 3 min". That
/// is the format for a countdown, not for saying when something happened.
enum RNSDate {

    /// When an event happened, the way a messages/mail list says it: a time
    /// today, "Yesterday", a weekday within the past week, a date beyond that.
    static func listTimestamp(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        // Calendar days between the two, measured from `now` — not from the
        // real clock. `isDateInToday`/`isDateInYesterday` ignore an injected
        // `now` entirely, so the tests below agreed with this function only on
        // the day they were written and failed every day after.
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: now)).day ?? 0
        switch days {
        case 0:      return date.formatted(date: .omitted, time: .shortened)
        case 1:      return "Yesterday"
        case 2..<7:  return date.formatted(.dateTime.weekday(.abbreviated))
        // Beyond a week — and anything dated after `now`, which a peer with a
        // skewed clock can produce — gets an unambiguous date.
        default:     return date.formatted(date: .numeric, time: .omitted)
        }
    }

    /// How long ago something was, in words — "21 hours ago", "2 days ago".
    /// For recency ("last seen"), where the elapsed time *is* the point.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        agoFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let agoFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full            // "21 hours ago", not "21 hr"
        f.dateTimeStyle = .named        // "yesterday" rather than "1 day ago"
        return f
    }()
}

// MARK: - Clipboard

/// Cross-platform "copy this string to the pasteboard" — the single place the
/// UIPasteboard / NSPasteboard split is handled, replacing the copies that had
/// been inlined per-view.
func rnsCopyToPasteboard(_ string: String) {
    #if os(iOS)
    UIPasteboard.general.string = string
    #elseif os(macOS)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(string, forType: .string)
    #endif
}

// MARK: - Hash display helper

extension String {
    /// Formats a raw hex hash for display: first 8 chars … last 8 chars.
    var truncatedHash: String {
        guard count > 20 else { return self }
        return "\(prefix(8))…\(suffix(8))"
    }
}

// MARK: - Cross-platform named-asset loading

#if os(macOS)
import AppKit
#endif

/// Returns true-ish (non-nil) when a bundled asset with the given name exists.
/// Resolves through AppKit on macOS and UIKit on iOS without shadowing either
/// framework's image initializer.
private func loadBrandImage(named name: String) -> Any? {
    #if os(macOS)
    return NSImage(named: name)
    #else
    return UIImage(named: name)
    #endif
}

// MARK: - QR code generation (shared by IdentityView + Onboarding)

#if canImport(CoreImage)
/// One shared Core Image context for the whole app.
///
/// `CIContext()` builds a full render pipeline and Apple documents it as
/// expensive to create and intended for reuse. Constructing one per QR was the
/// single largest block of app code on the main thread — ~75 ms every time the
/// Identity screen appeared, on top of the render itself.
private let rnsCIContext = CIContext()

/// Rendered QR bitmaps keyed by "string@scale". Identity hashes are stable, so
/// this is effectively a one-entry cache that makes every revisit free.
private final class RNSQRCache: @unchecked Sendable {
    static let shared = RNSQRCache()
    private let lock = NSLock()
    private var store: [String: CGImage] = [:]

    func image(for key: String, build: () -> CGImage?) -> CGImage? {
        lock.lock()
        if let hit = store[key] { lock.unlock(); return hit }
        lock.unlock()
        // Built outside the lock: rendering is slow and two concurrent misses
        // rendering the same code is cheaper than serialising every caller.
        guard let made = build() else { return nil }
        lock.lock(); store[key] = made; lock.unlock()
        return made
    }
}

/// Renders the QR bitmap. Safe to call off the main thread.
private func rnsQRCGImage(_ string: String, scale: CGFloat) -> CGImage? {
    RNSQRCache.shared.image(for: "\(string)@\(scale)") {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return rnsCIContext.createCGImage(scaled, from: scaled.extent)
    }
}

private func rnsWrap(_ cg: CGImage) -> Image {
    #if canImport(UIKit)
    return Image(uiImage: UIImage(cgImage: cg))
    #else
    return Image(nsImage: NSImage(cgImage: cg, size: .zero))
    #endif
}
#endif

/// Generates a crisp QR-code SwiftUI `Image` for `string`, or `nil` if Core
/// Image is unavailable. Cross-platform (UIImage / NSImage under the hood).
/// Render it with `.interpolation(.none).resizable()` to keep the modules sharp.
///
/// Results are cached, but a *cold* call still renders synchronously — never
/// call this from a `body`. Prefer `rnsQRImageAsync` from a `.task`.
func rnsQRImage(_ string: String, scale: CGFloat = 6) -> Image? {
    #if canImport(CoreImage)
    return rnsQRCGImage(string, scale: scale).map(rnsWrap)
    #else
    return nil
    #endif
}

/// Renders the QR off the main thread, then hands back the `Image`.
///
/// QR generation cost ~170 ms of blocked main thread on first appearance —
/// enough to stall the navigation push animation and swallow the first taps on
/// the screen. Cache hits return without leaving the current thread.
func rnsQRImageAsync(_ string: String, scale: CGFloat = 6) async -> Image? {
    #if canImport(CoreImage)
    return await Task.detached(priority: .userInitiated) {
        rnsQRCGImage(string, scale: scale)
    }.value.map(rnsWrap)
    #else
    return nil
    #endif
}
