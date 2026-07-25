import XCTest
@testable import RetiOS

/// Locks down the *capture styling policy* of the Micron source editor —
/// which tree-sitter-micron `highlights.scm` capture name gets which colour
/// role and font weight.
///
/// Not a rendering test — the editor itself is a `UIViewRepresentable` over
/// Runestone and exists on **iOS/iPadOS only** (Runestone is UIKit-only),
/// which is not meaningfully assertable in a unit test anyway. That's exactly
/// why `MicronCaptureColor`, `MicronCaptureStyle` and `MicronCaptureStyling`
/// live *outside* the `#if os(iOS)` in MicronSourceEditor.swift: this suite
/// builds for the macOS destination too, and the styling *policy* is
/// UIKit-free and platform-independent even though the editor is not.
final class MicronSourceEditorTests: XCTestCase {

    /// Every capture name tree-sitter-micron's own `queries/highlights.scm`
    /// actually emits (mirrored in `MicronTreeSitterLanguage.swift`). Pinning
    /// the full set, not just a sample, is what catches a capture silently
    /// falling through to "unstyled" when the query file gains a new one.
    private let realCaptureNames: Set<String> = [
        "comment",
        "property", "string",
        "punctuation.special", "markup.heading",
        "markup.bold", "markup.italic", "markup.underline", "function.builtin",
        "keyword",
        "constant.numeric",
        "markup.link", "markup.link.label", "markup.link.url",
        "attribute", "variable", "constant.builtin",
        "label",
        "string.escape",
        "markup.raw.block",
        "number",
    ]

    func testEveryRealCaptureNameIsStyled() {
        for name in realCaptureNames {
            XCTAssertNotNil(MicronCaptureStyling.style(for: name),
                            "\(name) is emitted by highlights.scm but has no style — it would render as plain text")
        }
    }

    func testUnknownCaptureNameReturnsNilRatherThanCrashing() {
        XCTAssertNil(MicronCaptureStyling.style(for: "not.a.real.capture"))
        XCTAssertNil(MicronCaptureStyling.style(for: ""))
    }

    func testLongestPrefixMatchFallsBackGracefully() {
        // Not a capture name tree-sitter-micron currently emits, but a
        // plausible future refinement of `markup.link.label`. The policy
        // must fall back to the parent rather than leaving it unstyled.
        let fallback = MicronCaptureStyling.style(for: "markup.link.label.hover")
        XCTAssertEqual(fallback, MicronCaptureStyling.styles["markup.link.label"])
    }

    func testHeadingsAreBoldAccent() {
        let style = MicronCaptureStyling.style(for: "markup.heading")
        XCTAssertEqual(style?.color, .accent)
        XCTAssertTrue(style?.bold ?? false)
    }

    func testCommentsAreMutedAndItalic() {
        let style = MicronCaptureStyling.style(for: "comment")
        XCTAssertEqual(style?.color, .textMuted)
        XCTAssertTrue(style?.italic ?? false)
        XCTAssertFalse(style?.bold ?? true)
    }
}
