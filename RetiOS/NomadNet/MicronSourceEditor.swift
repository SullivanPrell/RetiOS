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
// line-number gutter, line-wrap control, a find interaction, and per-range
// background tints driven by the Micron lexer. Runestone is UIKit-only. It
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
//      delegate applying the same token tints. Gets colouring on any macOS.
//   3. A ruler-view gutter on top of (2). Explicitly out of scope: a
//      hand-rolled `NSRulerView` that stays aligned through wrapping, folding
//      and Dynamic Type is a project of its own, and getting it *nearly* right
//      is worse than not having it.
//
// Either (2) or (3) is what "bring Pages to the Mac" means. Re-adding a bare
// `TextEditor` is not.

// MARK: - Tint roles
//
// Cross-platform on purpose, and this must stay that way: RetiOSTests builds for
// both iOS and macOS (see project.yml) and MicronSourceEditorTests asserts over
// these two symbols, so putting them behind `#if os(iOS)` breaks the Mac test
// build. It is also the right split on the merits — the *decision* about what
// deserves a tint is design policy and is unit-testable without UIKit; only the
// colour it maps to is platform-specific. Keeping the policy here means a future
// Mac editor (see note 2 above) can adopt it without re-deriving it.

/// What a token means for the reader, for tinting purposes.
///
/// Deliberately coarse. The goal is "markup is separable from prose at a
/// glance", not a colour per token kind — a page where every construct gets its
/// own hue is less readable than one with no colour at all.
enum MicronTintRole: Equatable {
    /// Formatting and layout commands, and the fences that bracket verbatim
    /// regions. The bulk of the tinting.
    case control
    /// Short, dense delimiters around links and fields. Same hue as `.control`
    /// but stronger, because a one- or two-character run at 13% alpha is
    /// invisible next to a whole-line `divider` at the same alpha.
    case delimiter
    /// Anchors and partial includes — names that resolve to somewhere else.
    case reference
    /// Something the lexer could not make sense of.
    case problem
    /// Present in the file but never rendered to the reader.
    case nonContent
}

extension MicronTokenKind {
    /// The tint role for this kind, or `nil` to leave it as plain text.
    ///
    /// Prose and prose-adjacent kinds return `nil` by design. Tinting
    /// `literalBody`, `tableBody`, `headingText`, `linkLabel` or `fieldData`
    /// means tinting most of the document, and a page where the majority of
    /// glyphs sit on a coloured band reads as damaged, not as highlighted.
    /// `linkURL` and `fieldDescriptor` are structural but they are also the
    /// longest runs inside a link/field, so the surrounding delimiters carry
    /// the signal instead.
    var micronTintRole: MicronTintRole? {
        switch self {
        case .styleTag, .colorTag, .alignTag, .resetTag,
             .sectionReset, .divider,
             .literalFence, .tableFence:
            return .control
        case .linkDelimiter, .fieldDelimiter:
            return .delimiter
        case .anchor, .partial:
            return .reference
        case .unknownCommand, .droppedHeadingMarker:
            // Both are markup the author wrote that the parser discards. Marking
            // them is the whole point: a dropped heading marker is otherwise
            // pixel-identical to one that works.
            return .problem
        case .comment, .escape:
            return .nonContent
        case .literalBody, .tableBody,
             .headingMarker, .headingText,
             .linkLabel, .linkURL, .linkField,
             .fieldDescriptor, .fieldData:
            return nil
        }
    }
}

#if os(iOS)

// MARK: - The editor

/// A source editor for Micron (`.mu`) documents — a `UIViewRepresentable` over
/// Runestone's `TextView`.
///
/// `tokens` is the lexer output for the *current* `text`. The view treats it as
/// advisory decoration: ranges are clamped to the document before use, so a
/// stale token array (one lex behind the keystroke) degrades to slightly wrong
/// tints rather than a crash. Pass `[]` to disable tinting entirely.
///
/// This is the first `*Representable` in RetiOS, so the lifecycle is spelled
/// out rather than assumed:
///
///   `makeCoordinator()` runs once per identity and owns the only long-lived
///   state — the delegate object and the last highlight set. It must not touch
///   the view (there isn't one yet).
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
    var tokens: [MicronToken] = []
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
        // one shot. `TextViewState(text:theme:)` — the initializer with no
        // `language:` — selects `PlainTextInternalLanguageMode`, which is what
        // we want: there is no Tree-sitter grammar for Micron, and there is no
        // way to supply one from outside the package (`LanguageMode` is an
        // empty marker protocol whose internal factory refuses third-party
        // conformers). All Micron colour therefore comes from
        // `highlightedRanges`, below.
        //
        // Runestone recommends building the state off the main queue for large
        // documents. Not done here: a NomadNet page is a few kilobytes, and
        // hopping queues would mean the view renders empty for a frame on every
        // externally-driven load (file open, page switch). Revisit if this
        // editor is ever pointed at something big.
        view.setState(TextViewState(text: text, theme: MicronEditorTheme.shared))

        apply(tokens: tokens, to: view, coordinator: context.coordinator)
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
            uiView.setState(TextViewState(text: text, theme: MicronEditorTheme.shared),
                            addUndoAction: true)
        }

        // After the text, always: a highlight range is an offset into whatever
        // string is currently installed.
        apply(tokens: tokens, to: uiView, coordinator: context.coordinator)
    }

    /// Converts tokens to `HighlightedRange`s and installs them, skipping the
    /// setter when nothing actually changed.
    private func apply(tokens: [MicronToken], to view: TextView, coordinator: Coordinator) {
        let ranges = MicronHighlight.ranges(for: tokens, documentLength: text.utf16.count)
        // `highlightedRanges`' setter pushes into the layout manager *and* the
        // highlight-navigation controller, so it is not free. `HighlightedRange`
        // compares on id/range/colour; the ids are derived from the token index
        // (not fresh UUIDs) and the colours are shared singletons, so an
        // unchanged token array really does compare equal here.
        // Compare against what the VIEW actually has, not a private cache.
        // `highlightedRanges` is shared with UIKit's find interaction: ending a
        // find session calls `clearAllDecoratedFoundText()`, which assigns `[]`
        // and wipes every Micron tint. A cache-based comparison then found
        // `ranges == lastHighlights`, skipped the setter, and the tints never
        // came back for the rest of the session.
        //
        // Find's own decorations carry UUID ids, ours are "micron-" prefixed, so
        // the two are separable: preserve theirs and splice ours alongside.
        let foreign = view.highlightedRanges.filter { !$0.id.hasPrefix(Self.highlightIDPrefix) }
        let combined = foreign + ranges
        guard combined != view.highlightedRanges else { return }
        coordinator.lastHighlights = ranges
        view.highlightedRanges = combined
    }

    /// Namespace for ids this view owns, so find-interaction decorations sharing
    /// `highlightedRanges` can be told apart from Micron tints.
    static let highlightIDPrefix = "micron-"

    /// Delegate target and owner of the representable's mutable state.
    ///
    /// A class, and retained by SwiftUI for the lifetime of the view's
    /// identity, which is what makes it safe for `editorDelegate` — a `weak`
    /// reference that would otherwise be nil by the time the user typed.
    final class Coordinator: TextViewDelegate {
        var text: Binding<String>
        /// The highlight set currently installed on the view, so an unchanged
        /// token array can skip the setter. Deliberately the *only* mutable
        /// state here: the text round-trip is guarded by comparing the view to
        /// the binding, not by a mirror copy that could drift out of sync.
        var lastHighlights: [HighlightedRange] = []

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

// MARK: - Token tints

private enum MicronHighlight {
    /// Corner radius on the tint. Rounded rather than square because these
    /// bands butt directly against untinted prose; a hard edge reads as a
    /// selection, a soft one as a highlight.
    private static let cornerRadius: CGFloat = 3

    /// Shared, so `HighlightedRange`'s `==` (which compares `UIColor` by
    /// `isEqual:`) sees identical instances and the change check in
    /// `apply(tokens:to:coordinator:)` can short-circuit.
    private static let control    = tint(Color.rnsAccent,  alpha: 0.13)
    private static let delimiter  = tint(Color.rnsAccent,  alpha: 0.22)
    private static let reference  = tint(Color.rnsSuccess, alpha: 0.15)
    private static let problem    = tint(Color.rnsWarning, alpha: 0.26)
    private static let nonContent = tint(Color.rnsTextSecondary, alpha: 0.10)

    /// Builds a *dynamic* translucent colour from a brand token.
    ///
    /// The wrapping closure is the point. `UIColor.withAlphaComponent(_:)`
    /// called directly on a dynamic colour resolves it against the traits in
    /// effect at the moment of the call — which, for a `static let`, is
    /// whatever the process happened to be in at first touch. The editor would
    /// then keep Light-mode tints forever after a switch to Dark. Resolving
    /// *inside* `UIColor { traits in ... }` defers it to draw time, per trait
    /// collection, which is the behaviour every other colour in the app has.
    private static func tint(_ color: Color, alpha: CGFloat) -> UIColor {
        let base = UIColor(color)
        return UIColor { traits in
            base.resolvedColor(with: traits).withAlphaComponent(alpha)
        }
    }

    private static func color(for role: MicronTintRole) -> UIColor {
        switch role {
        case .control:    return control
        case .delimiter:  return delimiter
        case .reference:  return reference
        case .problem:    return problem
        case .nonContent: return nonContent
        }
    }

    /// Maps tokens to highlight ranges, dropping anything untinted or outside
    /// the document.
    ///
    /// The clamp is not paranoia. `tokens` and `text` arrive as two independent
    /// arguments, and a caller that lexes asynchronously will hand us a token
    /// array one edit behind the string on the very next keystroke after a
    /// deletion. Runestone indexes its line manager with these ranges directly.
    static func ranges(for tokens: [MicronToken], documentLength: Int) -> [HighlightedRange] {
        guard documentLength > 0 else { return [] }
        let document = NSRange(location: 0, length: documentLength)
        var result: [HighlightedRange] = []
        result.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            guard let role = token.kind.micronTintRole else { continue }
            let clamped = NSIntersectionRange(token.range, document)
            guard clamped.length > 0 else { continue }
            result.append(
                HighlightedRange(
                    // Index-derived rather than a fresh UUID, so an unchanged
                    // token array produces an equal highlight array.
                    id: "micron-\(index)",
                    range: clamped,
                    color: color(for: role),
                    cornerRadius: cornerRadius
                )
            )
        }
        return result
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
/// The syntax-colouring half of the protocol (`textColor(for:)`,
/// `font(for:)`, `fontTraits(for:)`, `shadow(for:)`) is dead weight here — it
/// is only consulted for Tree-sitter capture names, and plain-text mode emits
/// none. It is still implemented explicitly, so that if a grammar ever does
/// appear the compiler points at this type.
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

    // MARK: Tree-sitter capture styling — unreachable in plain-text mode.

    func textColor(for highlightName: String) -> UIColor? { nil }
    func font(for highlightName: String) -> UIFont? { nil }
    func fontTraits(for highlightName: String) -> FontTraits { [] }
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
