import SwiftUI
#if os(iOS)
import UIKit
import Runestone
#endif

// MARK: - iOS/iPadOS only (read this before filing a bug)
//
// The Micron source editor exists on iOS and iPadOS and nowhere else. That is
// not an oversight and not a phased rollout — it is a hard platform constraint
// that the Mac build is now honest about instead of papering over.
//
// The editor is Runestone's `TextView`: a code-editor surface with a
// line-number gutter, line-wrap control, a find interaction, and real
// Tree-sitter syntax highlighting (see MicronTreeSitterLanguage.swift and
// MicronEditorTheme below). Runestone is UIKit-only. It
// subclasses `UIScrollView`, conforms to `UITextInput`, and its whole appearance
// layer (`Theme`, `HighlightedRange`, `DefaultTheme`) is typed in
// `UIFont`/`UIColor`. Its `Package.swift` declares `platforms: [.iOS(.v14)]` and
// nothing else. It is linked here with XcodeGen `destinationFilters: [iOS]`
// precisely so the Mac slice never tries to compile it — so **every** `Runestone`
// symbol below must stay inside `#if os(iOS)`. Mac Catalyst would build it, but
// RetiOS ships a native Mac target, not Catalyst.
//
// This file used to carry a macOS branch: a plain SwiftUI `TextEditor` in a
// monospaced face, with no gutter, no colouring and no find bar. It was removed
// deliberately. A page author cannot tell whether markup is right without seeing
// it separated from prose, so that surface was not a smaller version of the
// editor — it was a worse tool wearing the same name. Rather than ship it, the
// whole Pages section is compiled out of the Mac slice: `NomadSection` has no
// `.pages` case there (see NomadNetContainerView), and PagesView.swift and
// MicronPageEditorView.swift are `#if os(iOS)` in their entirety.
//
// What would close the gap, in increasing order of cost — kept as the record of
// what a Mac version would actually take, should anyone want to build one:
//   1. Raise the macOS floor to 26 and use the attributed `TextEditor`
//      (`Binding<AttributedString>`), which gives colouring — but still no
//      gutter. Cheapest real improvement; blocked today by the macOS 14 floor.
//   2. An `NSViewRepresentable` over `NSTextView` with a `NSTextStorage`
//      delegate applying the same Tree-sitter-driven colours. Gets colouring
//      on any macOS.
//   3. A ruler-view gutter on top of (2). Explicitly out of scope: a
//      hand-rolled `NSRulerView` that stays aligned through wrapping, folding
//      and Dynamic Type is a project of its own, and getting it *nearly* right
//      is worse than not having it.
//
// Either (2) or (3) is what "bring Pages to the Mac" means. Re-adding a bare
// `TextEditor` is not.

// MARK: - Tree-sitter capture styling (portable policy)
//
// Which colour role and font weight each tree-sitter-micron `highlights.scm`
// capture name maps to. Plain data only — no UIKit, no Runestone — so this
// lives outside the `#if os(iOS)` gate below and stays unit-testable on the
// macOS destination too. `RetiOSTests` builds for both destinations, and this
// mapping is the one part of the theme that isn't actually iOS-specific —
// the same reason `MicronTintRole` used to live out here before this file
// grew real Tree-sitter highlighting.

/// A colour role from the RNS brand palette (`Design/RNSBrand.swift`).
/// Deliberately not resolved to `UIColor` here — `UIColor` is UIKit, and this
/// type must build on macOS for `RetiOSTests`. See `MicronEditorTheme` below
/// for the half of this that does resolve to `UIColor`, which has no reason
/// to exist outside iOS and stays inside the guard.
enum MicronCaptureColor: Equatable {
    case accent, textPrimary, textSecondary, success, info, textMuted
}

struct MicronCaptureStyle: Equatable {
    let color: MicronCaptureColor
    let bold: Bool
    let italic: Bool
}

/// tree-sitter-micron's `queries/highlights.scm` capture names, mapped to a
/// colour and weight. Real, per-construct colour (closer to VS Code/Zed)
/// rather than the Pages editor's earlier background-tint scheme, which this
/// replaces. Every colour is drawn from the existing RNS palette — no new
/// hues introduced. `rnsWarning`/`rnsError` are deliberately excluded: they
/// are load-bearing for `MicronLinter`'s actual-problem signal elsewhere in
/// this screen, and reusing them for ordinary syntax colouring would blur a
/// distinction the app keeps sharp on purpose.
enum MicronCaptureStyling {
    static let styles: [String: MicronCaptureStyle] = [
        "markup.heading":      MicronCaptureStyle(color: .accent, bold: true, italic: false),
        "function.builtin":    MicronCaptureStyle(color: .accent, bold: true, italic: false),
        "keyword":             MicronCaptureStyle(color: .accent, bold: false, italic: false),
        "markup.link":         MicronCaptureStyle(color: .accent, bold: false, italic: false),
        "markup.bold":         MicronCaptureStyle(color: .textPrimary, bold: true, italic: false),
        "markup.italic":       MicronCaptureStyle(color: .textPrimary, bold: false, italic: true),
        "markup.underline":    MicronCaptureStyle(color: .textPrimary, bold: false, italic: false),
        "markup.link.label":   MicronCaptureStyle(color: .textPrimary, bold: false, italic: false),
        "markup.link.url":     MicronCaptureStyle(color: .textSecondary, bold: false, italic: false),
        "markup.raw.block":    MicronCaptureStyle(color: .textSecondary, bold: false, italic: false),
        "string":              MicronCaptureStyle(color: .textSecondary, bold: false, italic: false),
        "constant.numeric":    MicronCaptureStyle(color: .success, bold: false, italic: false),
        "number":              MicronCaptureStyle(color: .success, bold: false, italic: false),
        "constant.builtin":    MicronCaptureStyle(color: .success, bold: true, italic: false),
        "variable":            MicronCaptureStyle(color: .info, bold: false, italic: false),
        "attribute":           MicronCaptureStyle(color: .info, bold: true, italic: false),
        "label":               MicronCaptureStyle(color: .info, bold: true, italic: false),
        "property":            MicronCaptureStyle(color: .info, bold: false, italic: false),
        "comment":             MicronCaptureStyle(color: .textMuted, bold: false, italic: true),
        "string.escape":       MicronCaptureStyle(color: .textMuted, bold: false, italic: false),
        "punctuation.special": MicronCaptureStyle(color: .textMuted, bold: false, italic: false),
    ]

    /// Longest dotted-prefix match, per Runestone's own documented pattern
    /// (`CreatingATheme.md`'s `findLongestMatch`) — e.g. a future
    /// `markup.link.label.something` capture would fall back through
    /// `markup.link.label`, then `markup.link`, rather than going unstyled.
    /// Every capture tree-sitter-micron's own `highlights.scm` actually emits
    /// matches `styles` directly on the first try; the fallback is for
    /// forwards-compatibility with captures added there later.
    static func style(for highlightName: String) -> MicronCaptureStyle? {
        var components = highlightName.components(separatedBy: ".")
        while !components.isEmpty {
            let candidate = components.joined(separator: ".")
            if let match = styles[candidate] { return match }
            components.removeLast()
        }
        return nil
    }
}

#if os(iOS)

// MARK: - The editor

/// A source editor for Micron (`.mu`) documents — a `UIViewRepresentable` over
/// Runestone's `TextView`.
///
/// This is the first `*Representable` in RetiOS, so the lifecycle is spelled
/// out rather than assumed:
///
///   `makeCoordinator()` runs once per identity and owns the only long-lived
///   state — the delegate object. It must not touch the view (there isn't one
///   yet).
///
///   `makeUIView(context:)` runs once. All *static* configuration goes here.
///   Setting it in `updateUIView` instead would re-apply it on every SwiftUI
///   invalidation, and several of Runestone's setters have `didSet` side
///   effects (`isEditable` can force-resign first responder, `theme` triggers a
///   full re-layout) that are not free to repeat.
///
///   `updateUIView(_:context:)` runs on every invalidation of the enclosing
///   view — which, for a bound `String`, means *every keystroke*. It must
///   therefore be cheap and, above all, idempotent.
struct MicronSourceEditor: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.editorDelegate = context.coordinator

        // Markup editing, not prose editing. Every one of these is a
        // correctness fix, not a preference: iOS will happily turn `"` into a
        // curly quote and `--` into an em dash, and Micron's parser does not
        // recognise either. Autocapitalisation alone silently breaks
        // lower-case tag names.
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable

        view.showLineNumbers = true
        view.lineSelectionDisplayType = .line
        view.isLineWrappingEnabled = true
        view.lineBreakMode = .byWordWrapping
        // Micron is space-indented in every reference page NomadNet ships.
        view.indentStrategy = .space(length: 2)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 4, bottom: 12, right: 12)
        // Lets the last line scroll clear of the keyboard instead of sitting
        // flush against it.
        view.verticalOverscrollFactor = 0.3
        view.isFindInteractionEnabled = true

        view.backgroundColor = UIColor(Color.rnsCanvas)
        let accent = UIColor(Color.rnsAccent)
        view.insertionPointColor = accent
        view.selectionBarColor = accent
        view.selectionHighlightColor = accent.withAlphaComponent(0.25)

        view.isEditable = isEditable

        // `setState` is the documented way to install text + theme, and the
        // only one that builds the line manager and runs the initial parse in
        // one shot. `language: .micron` (MicronTreeSitterLanguage.swift) wraps
        // tree-sitter-micron's compiled grammar via Runestone's public
        // `TreeSitterLanguage` API, so Runestone parses the document for real
        // and calls `MicronEditorTheme.textColor(for:)`/`fontTraits(for:)` per
        // capture — that's where the actual Micron colours come from now.
        //
        // Runestone recommends building the state off the main queue for large
        // documents. Not done here: a NomadNet page is a few kilobytes, and
        // hopping queues would mean the view renders empty for a frame on every
        // externally-driven load (file open, page switch). Revisit if this
        // editor is ever pointed at something big.
        view.setState(TextViewState(text: text, theme: MicronEditorTheme.shared, language: .micron))

        return view
    }

    func updateUIView(_ uiView: TextView, context: Context) {
        // The coordinator outlives any single `self`, so refresh its binding
        // handle before anything can call back into it.
        context.coordinator.text = $text

        if uiView.isEditable != isEditable {
            uiView.isEditable = isEditable
        }

        // The binding round-trip, and the one thing in this file most likely to
        // be "simplified" back into a bug.
        //
        // NEVER assign `uiView.text` here. Runestone's `text` setter swaps the
        // backing `StringView` without rebuilding the line manager or clearing
        // the per-line controllers, which leaves stale layout objects pointing
        // into a string that no longer exists — the cause of several open
        // upstream crash reports. `setState` is the supported path and does
        // rebuild everything (including clamping the selection, so we do not
        // have to save and restore it).
        //
        // And a reload here is only ever correct for a change that came from
        // *outside* the editor. When the user types, `textViewDidChange` writes
        // the binding, SwiftUI re-invalidates, and we land right back here — at
        // which point the view's text and the binding are already identical, so
        // the comparison below is itself the re-entrancy guard. That is why it
        // compares view-to-binding rather than tracking an "isUpdating" flag:
        // a flag has to be cleared correctly on every path, and this cannot get
        // out of sync by construction.
        //
        // The comparison bridges an `NSMutableString` to `String` each pass. At
        // page size that is far cheaper than a needless full re-layout.
        if uiView.text != text {
            // `addUndoAction: true`, NOT the default. `setState` defaults to
            // false, which REPLACES the document without registering an undo
            // operation — and that discards the whole existing undo stack. Every
            // insert-palette tap and every builder sheet goes through this path
            // (they mutate the binding, not the view), so with the default a
            // single "Bold" tap made every keystroke before it un-undoable.
            // With true, the replacement registers as one undo group and prior
            // history survives.
            uiView.setState(TextViewState(text: text, theme: MicronEditorTheme.shared, language: .micron),
                            addUndoAction: true)
        }
    }

    /// Delegate target and owner of the representable's mutable state.
    ///
    /// A class, and retained by SwiftUI for the lifetime of the view's
    /// identity, which is what makes it safe for `editorDelegate` — a `weak`
    /// reference that would otherwise be nil by the time the user typed.
    final class Coordinator: TextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: TextView) {
            let new = textView.text
            // Guard the write as well as the read. Writing an unchanged value
            // still invalidates the SwiftUI view tree, and `textViewDidChange`
            // fires for edits that leave the string identical.
            guard new != text.wrappedValue else { return }
            text.wrappedValue = new
        }
    }
}

// MARK: - Theme

/// Runestone `Theme` wired to the RNS design tokens, so the editor sits in the
/// app rather than next to it.
///
/// `Theme` is `AnyObject`-constrained and Runestone holds it for the lifetime
/// of the state, hence the shared instance: a fresh theme per `setState` would
/// churn the layout manager's font metrics for no reason.
///
/// `textColor(for:)`/`fontTraits(for:)` map tree-sitter-micron's
/// `queries/highlights.scm` capture names to real per-token colours via
/// `MicronCaptureStyling` (above, outside the iOS gate so the mapping stays
/// testable on macOS too). Runestone passes capture names through verbatim,
/// with no fallback matching of its own (confirmed against its source), so
/// `MicronCaptureStyling.style(for:)` implements the dotted-prefix fallback
/// Runestone's own `CreatingATheme.md` documents as the theme's
/// responsibility.
///
/// `gutterHairlineWidth`, `pageGuideHairlineWidth` and
/// `markedTextBackgroundCornerRadius` are intentionally left to the protocol
/// extension's defaults. Those defaults return Runestone's internal
/// `hairlineLength` (`1 / UIScreen.main.scale`), which is not reachable from
/// outside the package; re-deriving it here would hardcode a value that the
/// package is free to change and would need its own screen-scale lookup.
private final class MicronEditorTheme: Theme {
    static let shared = MicronEditorTheme()

    /// Dynamic Type-aware, but capped. Runestone caches an estimated line
    /// height off `theme.font` when the state is built, so this is sampled at
    /// state-construction time — a content-size change mid-session needs a new
    /// `setState` to take effect. The cap keeps the gutter from eating half the
    /// width at the top accessibility sizes.
    let font: UIFont = UIFontMetrics(forTextStyle: .body).scaledFont(
        for: .monospacedSystemFont(ofSize: 14, weight: .regular),
        maximumPointSize: 28
    )
    let lineNumberFont: UIFont = UIFontMetrics(forTextStyle: .caption1).scaledFont(
        for: .monospacedSystemFont(ofSize: 12, weight: .regular),
        maximumPointSize: 22
    )

    let textColor = UIColor(Color.rnsTextPrimary)

    let gutterBackgroundColor = UIColor(Color.rnsCanvas)
    let gutterHairlineColor = UIColor(Color.rnsBorder)
    let lineNumberColor = UIColor(Color.rnsTextMuted)

    let selectedLineBackgroundColor = UIColor(Color.rnsSurface)
    let selectedLinesLineNumberColor = UIColor(Color.rnsTextSecondary)
    let selectedLinesGutterBackgroundColor = UIColor(Color.rnsSurfaceRaised)

    let invisibleCharactersColor = UIColor(Color.rnsTextMuted)

    let pageGuideHairlineColor = UIColor(Color.rnsBorder)
    let pageGuideBackgroundColor = UIColor(Color.rnsSurface)

    let markedTextBackgroundColor = UIColor(Color.rnsSurfaceRaised)

    private init() {}

    // MARK: Tree-sitter capture styling
    //
    // The capture → colour/weight policy itself is `MicronCaptureStyling`,
    // above the `#if os(iOS)` guard. What's left here is resolving each
    // `MicronCaptureColor` to a dynamic `UIColor`, which has no reason to
    // exist outside iOS.

    private static let accentColor = resolvedColor(Color.rnsAccent)
    private static let textPrimaryColor = resolvedColor(Color.rnsTextPrimary)
    private static let textSecondaryColor = resolvedColor(Color.rnsTextSecondary)
    private static let successColor = resolvedColor(Color.rnsSuccess)
    private static let infoColor = resolvedColor(Color.rnsInfo)
    private static let textMutedColor = resolvedColor(Color.rnsTextMuted)

    /// Resolves a brand `Color` to a *dynamic* `UIColor` — deferred to draw
    /// time, per trait collection, so it doesn't go stale across a Light/Dark
    /// switch the way a plain `UIColor(Color.x)` captured once at first touch
    /// would.
    private static func resolvedColor(_ color: Color) -> UIColor {
        let base = UIColor(color)
        return UIColor { traits in base.resolvedColor(with: traits) }
    }

    private static func uiColor(for captureColor: MicronCaptureColor) -> UIColor {
        switch captureColor {
        case .accent: return accentColor
        case .textPrimary: return textPrimaryColor
        case .textSecondary: return textSecondaryColor
        case .success: return successColor
        case .info: return infoColor
        case .textMuted: return textMutedColor
        }
    }

    func textColor(for highlightName: String) -> UIColor? {
        MicronCaptureStyling.style(for: highlightName).map { Self.uiColor(for: $0.color) }
    }

    func font(for highlightName: String) -> UIFont? { nil }

    func fontTraits(for highlightName: String) -> FontTraits {
        guard let style = MicronCaptureStyling.style(for: highlightName) else { return [] }
        var traits: FontTraits = []
        if style.bold { traits.insert(.bold) }
        if style.italic { traits.insert(.italic) }
        return traits
    }

    func shadow(for highlightName: String) -> NSShadow? { nil }

    // MARK: Find interaction

    /// Overridden only to move the find highlights onto the brand accent; the
    /// protocol's default uses `systemYellow`, which collides with nothing in
    /// this file but matches nothing in the app either.
    func highlightedRange(forFoundTextRange foundTextRange: NSRange,
                          ofStyle style: UITextSearchFoundTextStyle) -> HighlightedRange? {
        let accent = UIColor(Color.rnsAccent)
        switch style {
        case .found:
            return HighlightedRange(range: foundTextRange,
                                    color: accent.withAlphaComponent(0.22),
                                    cornerRadius: 3)
        case .highlighted:
            return HighlightedRange(range: foundTextRange,
                                    color: accent.withAlphaComponent(0.45),
                                    cornerRadius: 3)
        case .normal:
            return nil
        @unknown default:
            return nil
        }
    }
}

#endif
