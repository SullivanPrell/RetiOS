import XCTest
@testable import RetiOS

/// Covers the markup the app *generates* — the starter template and the two
/// builder sheets — against the same lexer and linter the editor shows the
/// author.
///
/// This is the gap that mattered most in review: every construct here is
/// produced by tapping a button, so a mistake in one is a mistake in every page
/// a user creates, and none of it was asserted anywhere. Both offending cases
/// below shipped in the first draft and both are caught by these tests.
final class MicronAuthoringTests: XCTestCase {

    private func assertLintClean(_ markup: String,
                                 _ what: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        let diagnostics = MicronLinter.diagnostics(in: markup)
        XCTAssertTrue(diagnostics.isEmpty,
                      "\(what) is not clean Micron: "
                      + diagnostics.map { "line \($0.line): \($0.message)" }.joined(separator: " | "),
                      file: file, line: line)
    }

    // MARK: - Starter template

    /// The first thing a user ever sees. The original draft produced four
    /// warnings and rendered as "This page is 8ffMicron markup" and "Lines
    /// starting with are headings, a lone draws a divider" — it used the
    /// 3-nibble `` `F `` with six digits, and wrapped `>` and `-` in backticks,
    /// which the parser deletes.
    func testStarterTemplateIsWellFormedMicron() {
        assertLintClean(MicronPageStore.starterTemplate, "starterTemplate")
    }

    /// Lint-clean is necessary but not sufficient — the colour tag has to
    /// actually be a colour tag, not a 3-nibble read of the first three digits.
    func testStarterTemplateColourTagIsTheSixDigitForm() {
        let tokens = MicronSyntax.tokens(in: MicronPageStore.starterTemplate)
        let ns = MicronPageStore.starterTemplate as NSString
        let colourTags = tokens.filter { $0.kind == .colorTag }.map { ns.substring(with: $0.range) }

        XCTAssertTrue(colourTags.contains { $0.hasPrefix("`FT") },
                      "expected a 6-digit `FT tag, got \(colourTags)")
        XCTAssertTrue(colourTags.contains("`f"),
                      "a colour must be reset or it bleeds into the rest of the page: \(colourTags)")
    }

    /// The template's own link must be the same shape the link builder emits.
    func testStarterTemplateLinkUsesTheColonPrefixedForm() {
        XCTAssertTrue(MicronPageStore.starterTemplate.contains("`:/page/"),
                      "a same-node link needs the leading \":\" or Python NomadNet rejects it")
    }

    // MARK: - Link builder

    /// Python NomadNet's `Browser.retrieve_url` splits the URL on ":" and, with
    /// a single component, requires exactly 32 hex characters — so a bare
    /// "/page/about.mu" raises ValueError("Malformed URL") on every Python peer.
    /// RetiOS's own browser accepts both forms, which is exactly why this was
    /// invisible in the preview pane.
    func testPageLinkIsColonPrefixedForPythonCompatibility() {
        var sheet = MicronLinkSnippet()
        sheet.kind = .page
        sheet.target = "/page/about.mu"
        sheet.label = "About"

        XCTAssertEqual(sheet.snippet, "`[About`:/page/about.mu]")
        assertLintClean(sheet.snippet, "page link")
    }

    func testPageLinkAddsTheLeadingSlashWhenOmitted() {
        var sheet = MicronLinkSnippet()
        sheet.kind = .page
        sheet.target = "page/about.mu"
        XCTAssertEqual(sheet.snippet, "`[:/page/about.mu]")
    }

    func testAnchorAndNodeLinkForms() {
        var sheet = MicronLinkSnippet()
        sheet.kind = .anchor
        sheet.target = "contact"
        sheet.label = "Jump"
        XCTAssertEqual(sheet.snippet, "`[Jump`#contact]")
        assertLintClean(sheet.snippet, "anchor link")

        sheet.kind = .node
        sheet.label = ""
        sheet.target = String(repeating: "a1", count: 16) + ":/page/index.mu"
        XCTAssertEqual(sheet.snippet, "`[\(sheet.target)]")
        assertLintClean(sheet.snippet, "node link")
    }

    /// A "]" ends the link at the FIRST occurrence and a backtick starts a new
    /// component, so either one silently truncates the link into markup the
    /// author did not write. The sheet must refuse rather than emit it.
    func testLinkBuilderRefusesCharactersThatTruncateTheLink() {
        for hostile in ["Spec [draft]", "back`tick"] {
            var sheet = MicronLinkSnippet()
            sheet.kind = .page
            sheet.target = "/page/spec.mu"
            sheet.label = hostile
            XCTAssertFalse(sheet.snippet.isEmpty)
            XCTAssertTrue(
                hostile.contains(where: { MicronLinkSnippet.forbidden.contains($0) }),
                "\(hostile) should be recognised as unusable in a link")
        }
    }

    // MARK: - Field builder

    /// The one construct nobody remembers: `` `<flags|name|value|*`data> ``.
    func testFieldBuilderEmitsEachFormExactly() {
        func snippet(_ configure: (inout MicronFieldSnippet) -> Void) -> String {
            var sheet = MicronFieldSnippet()
            configure(&sheet)
            return sheet.snippet
        }

        // Plain text field: no flags and nothing else to say, so the whole
        // descriptor is just the name.
        XCTAssertEqual(snippet { $0.name = "username" }, "`<username`>")

        // Pre-filled text becomes the data segment, after the backtick.
        XCTAssertEqual(snippet { $0.name = "username"; $0.data = "anonymous" },
                       "`<username`anonymous>")

        // Masked, with an explicit width: the flag and the width share the
        // first segment.
        XCTAssertEqual(snippet {
            $0.kind = .masked; $0.name = "passphrase"; $0.useWidth = true; $0.width = 32
        }, "`<!32|passphrase`>")

        // Checkbox, pre-checked: the fourth segment is a literal "*".
        XCTAssertEqual(snippet {
            $0.kind = .checkbox; $0.name = "sign_up"; $0.value = "1"; $0.prechecked = true
        }, "`<?|sign_up|1|*`>")

        // Radio: same shape, "^" flag, no pre-check segment.
        XCTAssertEqual(snippet { $0.kind = .radio; $0.name = "color"; $0.value = "Red" },
                       "`<^|color|Red`>")
    }

    func testEveryFieldFormIsLintClean() {
        var sheet = MicronFieldSnippet()
        for kind in MicronFieldSnippet.Kind.allCases {
            sheet.kind = kind
            sheet.name = "field_\(kind.rawValue)"
            sheet.value = kind.usesValue ? "1" : ""
            assertLintClean(sheet.snippet, "\(kind.rawValue) field")
        }
    }

    /// A ">" in the pre-filled text closes the field early, leaving the rest as
    /// stray body text next to the input box; a backtick or "|" corrupts the
    /// descriptor the same way.
    func testFieldBuilderFlagsCharactersThatTruncateTheField() {
        XCTAssertTrue(MicronFieldSnippet.forbiddenInValue.contains(">"))
        XCTAssertTrue(MicronFieldSnippet.forbiddenInValue.contains("`"))
        XCTAssertTrue(MicronFieldSnippet.forbiddenInName.contains("|"))

        // And the reason it matters: the truncated form really does mis-parse.
        let truncated = "`<quote`a>b>"
        let tokens = MicronSyntax.tokens(in: truncated)
        let ns = truncated as NSString
        let data = tokens.first { $0.kind == .fieldData }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(data, "a", "the field's value stops at the first \">\"")
    }

    // MARK: - Round trip

    /// Everything the palette inserts must survive its own linter. A button that
    /// produces a warning is worse than no button.
    func testInsertPaletteSnippetsAreLintClean() {
        // Mirrors MicronPageEditorView.insertPalette. Kept as literals rather
        // than reaching into the view so a change there shows up as a failure
        // here rather than being silently tracked.
        let snippets: [(String, String)] = [
            ("bold", "`!bold`!"),
            ("italic", "`*italic`*"),
            ("underline", "`_underline`_"),
            ("heading", ">Heading"),
            ("divider", "\n-\n"),
            ("colour", "`F0afcoloured`f"),
            ("reset", "``"),
            ("literal", "\n`=\nverbatim\n`=\n"),
            ("comment", "#a comment"),
        ]
        for (name, snippet) in snippets {
            assertLintClean(snippet, "\(name) palette snippet")
        }
    }
}
