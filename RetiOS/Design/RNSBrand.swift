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
    static var rnsSurface: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
    static var rnsSurfaceRaised: Color {
        #if canImport(UIKit)
        Color(uiColor: .tertiarySystemGroupedBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
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

// MARK: - Section picker (native segmented control)

/// A thin convenience wrapper over a native segmented `Picker`. Call sites keep
/// passing `[(label, value)]` plus a binding; this renders the standard system
/// segmented control — the HIG-native choice — instead of a custom underline
/// tab bar that had to hand-roll its own colors, animation, and a11y traits.
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
        .padding(.horizontal)
        .padding(.vertical, 8)
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
                Text(lastSeen, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
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

/// Generates a crisp QR-code SwiftUI `Image` for `string`, or `nil` if Core
/// Image is unavailable. Cross-platform (UIImage / NSImage under the hood).
/// Render it with `.interpolation(.none).resizable()` to keep the modules sharp.
func rnsQRImage(_ string: String, scale: CGFloat = 6) -> Image? {
    #if canImport(CoreImage)
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext()
    guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    #if canImport(UIKit)
    return Image(uiImage: UIImage(cgImage: cg))
    #elseif canImport(AppKit)
    return Image(nsImage: NSImage(cgImage: cg, size: .zero))
    #else
    return nil
    #endif
    #else
    return nil
    #endif
}
