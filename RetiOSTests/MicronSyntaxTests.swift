import XCTest
@testable import RetiOS

/// Every expectation here was derived by hand-executing
/// `NomadNetSwift/Sources/NomadNet/MicronParser.swift`, not by observing what
/// this lexer happened to produce. Where the parser's behaviour is surprising
/// the test says so — those are the cases where a "cleanup" of the lexer would
/// silently desync the editor from the renderer.
final class MicronSyntaxTests: XCTestCase {

    // MARK: - Helpers

    private typealias Expected = (kind: MicronTokenKind, location: Int, length: Int)

    private func assertTokens(
        _ text: String,
        _ expected: [Expected],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = MicronSyntax.tokens(in: text).map {
            ($0.kind, $0.range.location, $0.range.length)
        }
        let describe: ([(MicronTokenKind, Int, Int)]) -> String = { list in
            "[" + list.map { "\($0.0)(\($0.1),\($0.2))" }.joined(separator: ", ") + "]"
        }
        guard actual.count == expected.count,
              zip(actual, expected).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 })
        else {
            XCTFail("token mismatch\n  expected \(describe(expected.map { ($0.kind, $0.location, $0.length) }))"
                    + "\n  actual   \(describe(actual))",
                    file: file, line: line)
            return
        }
    }

    /// Substring covered by the nth token — proves the ranges are usable, not
    /// merely self-consistent.
    private func slice(_ text: String, _ index: Int) -> String {
        let token = MicronSyntax.tokens(in: text)[index]
        guard let range = Range(token.range, in: text) else { return "<invalid>" }
        return String(text[range])
    }

    private func messages(_ text: String) -> [String] {
        MicronLinter.diagnostics(in: text).map(\.message)
    }

    // MARK: - Degenerate documents

    func testEmptyDocumentProducesNothing() {
        assertTokens("", [])
        XCTAssertTrue(MicronLinter.diagnostics(in: "").isEmpty)
    }

    func testBlankLinesProduceNothing() {
        // `parse` short-circuits empty lines to `.emptyLine` without touching state.
        assertTokens("\n\n\n", [])
    }

    func testDocumentThatIsOnlyAFence() {
        assertTokens("`=", [(.literalFence, 0, 2)])
        let diagnostics = MicronLinter.diagnostics(in: "`=")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.severity, .error)
        XCTAssertEqual(diagnostics.first?.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(diagnostics.first?.line, 1)
    }

    func testPlainTextProducesNoTokens() {
        // There is no `text` kind: body text is the absence of a token.
        assertTokens("just some prose, 50% of it", [])
    }

    // MARK: - Line-anchored directives

    func testComment() {
        assertTokens("# a comment", [(.comment, 0, 11)])
    }

    func testCommentIsColumnZeroOnly() {
        assertTokens(" # not a comment", [])
    }

    func testHeadingLevels() {
        assertTokens(">One", [(.headingMarker, 0, 1), (.headingText, 1, 3)])
        assertTokens(">>Two", [(.headingMarker, 0, 2), (.headingText, 2, 3)])
        assertTokens(">>>Three", [(.headingMarker, 0, 3), (.headingText, 3, 5)])
    }

    func testHeadingContentIsStillTagParsed() {
        // `parseLine` runs heading content through `makeOutput`, so the text
        // arrives as runs either side of real tags.
        assertTokens(">A `!B", [
            (.headingMarker, 0, 1),
            (.headingText, 1, 2),
            (.styleTag, 3, 2),
            (.headingText, 5, 1),
        ])
    }

    func testHeadingContainingFieldOpenerLosesHeadingStatusEntirely() {
        // `first == ">" && line.contains("`<")` drops the whole ">" run and
        // re-treats the line as ordinary. The markers render as nothing — but
        // they still get a token, `.droppedHeadingMarker`, so the editor can
        // mark them as non-rendering and the linter can warn. Without it a
        // heading that works and one that silently does not were identical on
        // screen and both reported "No issues".
        assertTokens(">`<name`data>", [
            (.droppedHeadingMarker, 0, 1),
            (.fieldDelimiter, 1, 2),
            (.fieldDescriptor, 3, 4),
            (.fieldDelimiter, 7, 1),
            (.fieldData, 8, 4),
            (.fieldDelimiter, 12, 1),
        ])
    }

    func testSectionReset() {
        assertTokens("<", [(.sectionReset, 0, 1)])
    }

    func testSectionResetReparsesTheRemainderAsAWholeLine() {
        // parseLine recurses on the rest, so "<" can be followed by a heading,
        // a comment, or even the literal fence.
        assertTokens("<>Title", [
            (.sectionReset, 0, 1),
            (.headingMarker, 1, 1),
            (.headingText, 2, 5),
        ])
        assertTokens("<<<", [(.sectionReset, 0, 1), (.sectionReset, 1, 1), (.sectionReset, 2, 1)])
        assertTokens("<# gone", [(.sectionReset, 0, 1), (.comment, 1, 6)])
        assertTokens("<`=", [(.sectionReset, 0, 1), (.literalFence, 1, 2)])
    }

    func testDividerConsumesTheWholeLine() {
        assertTokens("-", [(.divider, 0, 1)])
        assertTokens("-=", [(.divider, 0, 2)])
        // Anything past the fill character is discarded by the parser, so the
        // token covers it rather than pretending it renders.
        assertTokens("-abc", [(.divider, 0, 4)])
    }

    // MARK: - Literal mode

    func testLiteralModeSuppressesTagRecognition() {
        let text = "`=\n`!bold\n`=\n`!bold"
        assertTokens(text, [
            (.literalFence, 0, 2),
            (.literalBody, 3, 6),
            (.literalFence, 10, 2),
            (.styleTag, 13, 2),
        ])
    }

    func testLiteralFenceMustBeTheEntireLine() {
        // "`= " is not a fence; it is a backtick followed by the command "=",
        // which `makeOutput` does not implement — so it is silently deleted.
        assertTokens("`= \nfoo", [(.unknownCommand, 0, 2)])
    }

    func testEscapedFenceInsideLiteralModeIsJustBody() {
        assertTokens("`=\n\\`=\n`=", [
            (.literalFence, 0, 2),
            (.literalBody, 3, 3),
            (.literalFence, 7, 2),
        ])
    }

    func testCommentInsideLiteralModeIsBody() {
        assertTokens("`=\n# not a comment\n`=", [
            (.literalFence, 0, 2),
            (.literalBody, 3, 15),
            (.literalFence, 19, 2),
        ])
    }

    // MARK: - Table mode

    func testTableFenceWithAlignmentAndWidth() {
        let text = "`tc40\nA | B\n`t"
        assertTokens(text, [
            (.tableFence, 0, 5),
            (.tableBody, 6, 5),
            (.tableFence, 12, 2),
        ])
    }

    func testTableFenceIsAnyLineStartingWithBacktickT() {
        // The align/width parse is lenient (`Int(rest)` simply fails), so junk
        // after "`t" does not stop it being a fence.
        assertTokens("`tzzz\nrow\n`t", [
            (.tableFence, 0, 5),
            (.tableBody, 6, 3),
            (.tableFence, 10, 2),
        ])
    }

    func testCommentInsideTableModeIsStillAComment() {
        // The comment check runs *before* table buffering, so a "#" line never
        // becomes a row.
        assertTokens("`t\n# x\nrow\n`t", [
            (.tableFence, 0, 2),
            (.comment, 3, 3),
            (.tableBody, 7, 3),
            (.tableFence, 11, 2),
        ])
    }

    func testEscapedTableFenceStillTogglesTableMode() {
        // The "`t" prefix test runs on the line *after* the escape prefix is
        // stripped, so a leading backslash does not protect it.
        assertTokens("\\`t\nrow", [
            (.escape, 0, 1),
            (.tableFence, 1, 2),
            (.tableBody, 4, 3),
        ])
    }

    func testLiteralFenceWinsInsideTableMode() {
        // The fence comparison is the very first thing parseLine does, ahead of
        // table buffering — so "`=" opens literal mode even mid-table.
        assertTokens("`t\n`=\nrow\n`=\n`t", [
            (.tableFence, 0, 2),
            (.literalFence, 3, 2),
            (.literalBody, 6, 3),
            (.literalFence, 10, 2),
            (.tableFence, 13, 2),
        ])
        XCTAssertTrue(MicronLinter.diagnostics(in: "`t\n`=\nrow\n`=\n`t").isEmpty)
    }

    func testTableBodyDoesNotRecogniseTags() {
        assertTokens("`t\n`!bold\n`t", [
            (.tableFence, 0, 2),
            (.tableBody, 3, 6),
            (.tableFence, 10, 2),
        ])
    }

    // MARK: - The escape prefix

    func testLeadingBackslashEscapesOnlyTheFirstCharacter() {
        // The parser's own header doc claims the remainder is literal. It is
        // not: `makeOutput` seeds `escape = preEscape` and the first character
        // processed clears it. So the trailing "`!" is a live tag.
        assertTokens("\\`!bold`!", [
            (.escape, 0, 1),
            (.styleTag, 7, 2),
        ])
    }

    func testEscapedBackslashThenLiveTag() {
        assertTokens("\\\\`!", [
            (.escape, 0, 1),
            (.styleTag, 2, 2),
        ])
    }

    func testMidLineBackslashEscapesTheNextCharacter() {
        assertTokens("a\\`!b", [(.escape, 1, 1)])
    }

    func testEscapePrefixDisarmsLineDirectivesButNotTableFences() {
        assertTokens("\\>not a heading", [(.escape, 0, 1)])
        assertTokens("\\-not a divider", [(.escape, 0, 1)])
        assertTokens("\\<not a reset", [(.escape, 0, 1)])
    }

    func testLineThatIsOnlyABackslash() {
        assertTokens("\\", [(.escape, 0, 1)])
    }

    // MARK: - Inline style, colour and alignment

    func testStyleAndResetTags() {
        assertTokens("`!x`_y`*z``", [
            (.styleTag, 0, 2),
            (.styleTag, 3, 2),
            (.styleTag, 6, 2),
            (.resetTag, 9, 2),
        ])
    }

    func testAlignmentTags() {
        assertTokens("`c`l`r`a", [
            (.alignTag, 0, 2),
            (.alignTag, 2, 2),
            (.alignTag, 4, 2),
            (.alignTag, 6, 2),
        ])
    }

    func testColourTags() {
        assertTokens("`F00f", [(.colorTag, 0, 5)])
        assertTokens("`FT00ff00", [(.colorTag, 0, 9)])
        assertTokens("`B0a0", [(.colorTag, 0, 5)])
        assertTokens("`BT112233", [(.colorTag, 0, 9)])
        assertTokens("`f`b", [(.colorTag, 0, 2), (.colorTag, 2, 2)])
    }

    func testGreyscaleColourIsValid() {
        // parseColor3 treats "gNN" as a decimal grey percentage.
        assertTokens("`Fg50", [(.colorTag, 0, 5)])
        XCTAssertTrue(MicronLinter.diagnostics(in: "`Fg50").isEmpty)
    }

    func testColourTagFollowedByText() {
        assertTokens("`F00fred", [(.colorTag, 0, 5)])
        XCTAssertEqual(slice("`F00fred", 0), "`F00f")
    }

    func testTruncatedSixDigitColourFallsBackToTheThreeDigitBranch() {
        // The two guards are independent: "`FT12" fails the 6-digit length test
        // and then feeds "T12" to parseColor3, which fails and yields default.
        assertTokens("`FT12", [(.colorTag, 0, 5)])
        XCTAssertEqual(messages("`FT12").count, 1)
        XCTAssertTrue(messages("`FT12")[0].contains("not a colour"))
    }

    func testColourWithTooFewCharactersDropsTheCommandOnly() {
        // "`F12": neither branch fits, so the switch falls through — the "`F"
        // vanishes and "12" renders as text.
        assertTokens("`F12", [(.colorTag, 0, 2)])
    }

    // MARK: - Anchors

    func testAnchor() {
        assertTokens("`:top-1 rest", [(.anchor, 0, 7)])
        XCTAssertEqual(slice("`:top-1 rest", 0), "`:top-1")
    }

    func testAnchorWithEmptyNameResumesAtTheVeryNextCharacter() {
        // The anchor branch `continue`s without the loop's i += 1, so the
        // character that ended the name is re-read in text mode.
        //
        // The terminator has to be something that PRODUCES A TOKEN, or the test
        // cannot fail: with a plain "!" the expected output is `[.anchor]`
        // whether the character is re-read or swallowed, so changing
        // `index = end; continue` to `index = end + 1` — desyncing the lexer
        // from the parser — would still pass. A backtick command does produce
        // one.
        assertTokens("`:`!x", [(.anchor, 0, 2), (.styleTag, 2, 2)])
        assertTokens("`:!x", [(.anchor, 0, 2)])
    }

    func testAnchorAtEndOfLine() {
        assertTokens("`:", [(.anchor, 0, 2)])
    }

    // MARK: - Links

    func testLinkWithOnlyOneComponentIsAUrlNotALabel() {
        assertTokens("`[url]", [
            (.linkDelimiter, 0, 2),
            (.linkURL, 2, 3),
            (.linkDelimiter, 5, 1),
        ])
    }

    func testLinkWithLabelAndUrl() {
        assertTokens("`[Label`url]", [
            (.linkDelimiter, 0, 2),
            (.linkLabel, 2, 5),
            (.linkDelimiter, 7, 1),
            (.linkURL, 8, 3),
            (.linkDelimiter, 11, 1),
        ])
    }

    func testLinkWithFields() {
        assertTokens("`[L`u`a|b]", [
            (.linkDelimiter, 0, 2),
            (.linkLabel, 2, 1),
            (.linkDelimiter, 3, 1),
            (.linkURL, 4, 1),
            (.linkDelimiter, 5, 1),
            (.linkField, 6, 3),
            (.linkDelimiter, 9, 1),
        ])
    }

    func testUnclosedLinkConsumesOnlyItsOpener() {
        // parseLink returning nil leaves i on the "[", so the parser deletes
        // just "`[" and renders "url" as text.
        assertTokens("`[url", [(.linkDelimiter, 0, 2)])
    }

    func testLinkWithEmptyUrlIsDiscardedEntirely() {
        assertTokens("`[]", [(.linkDelimiter, 0, 2)])
        // Only "`[" is consumed, so the rest is re-read as ordinary text — which
        // means the separator backtick now introduces a command, and "`]" is not
        // one. That second deletion is the parser's behaviour, not an artefact.
        assertTokens("`[label`]", [(.linkDelimiter, 0, 2), (.unknownCommand, 7, 2)])
    }

    // MARK: - Fields

    func testFieldWithFlags() {
        assertTokens("`<32|name`value>", [
            (.fieldDelimiter, 0, 2),
            (.fieldDescriptor, 2, 7),
            (.fieldDelimiter, 9, 1),
            (.fieldData, 10, 5),
            (.fieldDelimiter, 15, 1),
        ])
        XCTAssertEqual(slice("`<32|name`value>", 1), "32|name")
        XCTAssertEqual(slice("`<32|name`value>", 3), "value")
    }

    func testFieldWithEmptyData() {
        assertTokens("`<name`>", [
            (.fieldDelimiter, 0, 2),
            (.fieldDescriptor, 2, 4),
            (.fieldDelimiter, 6, 1),
            (.fieldDelimiter, 7, 1),
        ])
    }

    func testFieldWithNoBacktickIsNotAFieldAtAll() {
        assertTokens("`<name>", [(.fieldDelimiter, 0, 2)])
    }

    func testFieldWithNoClosingAngle() {
        // Same cascade as a malformed link: the "`<" is dropped, the rest is
        // rescanned as text, and the separator backtick then eats the "d".
        assertTokens("`<name`data", [(.fieldDelimiter, 0, 2), (.unknownCommand, 6, 2)])
    }

    // MARK: - Unknown commands

    func testUnknownCommandCharacter() {
        assertTokens("a`Qb", [(.unknownCommand, 1, 2)])
    }

    func testTrailingBacktick() {
        assertTokens("abc`", [(.unknownCommand, 3, 1)])
    }

    // MARK: - Partials

    func testPartialConsumesTheWholeLine() {
        assertTokens("`{/page/x`10}", [(.partial, 0, 13)])
    }

    func testUnclosedPartialStillConsumesTheWholeLine() {
        // parsePartial returns nil, but the branch has already claimed the line.
        assertTokens("`{unclosed", [(.partial, 0, 10)])
    }

    // MARK: - UTF-16 offsets

    func testMultibyteCharactersDoNotShiftLaterRanges() {
        // "é" is one UTF-16 unit, "😀" is a surrogate pair (two).
        let text = "é😀`!x"
        assertTokens(text, [(.styleTag, 3, 2)])
        XCTAssertEqual(slice(text, 0), "`!")
    }

    func testMultibyteCharactersInAnEarlierLine() {
        let text = "😀\n`[url]"
        assertTokens(text, [
            (.linkDelimiter, 3, 2),
            (.linkURL, 5, 3),
            (.linkDelimiter, 8, 1),
        ])
        XCTAssertEqual(slice(text, 1), "url")
    }

    func testEmojiInsideALinkLabel() {
        let text = "`[Hi 😀`u]"
        assertTokens(text, [
            (.linkDelimiter, 0, 2),
            (.linkLabel, 2, 5),
            (.linkDelimiter, 7, 1),
            (.linkURL, 8, 1),
            (.linkDelimiter, 9, 1),
        ])
        XCTAssertEqual(slice(text, 1), "Hi 😀")
    }

    func testGraphemeClusterCountsAllOfItsUnits() {
        // A ZWJ family is one Character but 11 UTF-16 units. If the lexer
        // counted Characters, every range after this would be 10 short.
        let text = "👨‍👩‍👧‍👦`!"
        let tokens = MicronSyntax.tokens(in: text)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].range, NSRange(location: 11, length: 2))
        XCTAssertEqual(slice(text, 0), "`!")
    }

    func testAnchorNameAcceptsNonASCIILetters() {
        // isLetter is Unicode-wide in both the parser and here.
        assertTokens("`:café ", [(.anchor, 0, 6)])
    }

    // MARK: - Coverage

    func testEveryTokenKindIsReachable() {
        // A kind no document can produce is either dead or a highlighting theme
        // entry that will never fire; either way it should not exist silently.
        let corpus = """
        # comment
        \\escaped
        `=
        literal
        `=
        `t
        a | b
        `t
        >>>Heading `!bold`!
        <
        -
        `c`F00f`f``
        `:anchor
        `{/page/p`5}
        `[Label`url`a|b]
        `<32|name`value>
        `Q
        >dropped heading `<f`v>
        """
        let produced = Set(MicronSyntax.tokens(in: corpus).map(\.kind))
        XCTAssertEqual(
            produced,
            Set(MicronTokenKind.allCases),
            "unreachable kinds: \(Set(MicronTokenKind.allCases).subtracting(produced))"
        )
    }

    // MARK: - Robustness

    func testPathologicalInputNeitherCrashesNorLoops() {
        let samples = [
            "`", "``", "```", "`[", "`[`", "`[`]", "`<", "`<`", "`<`>", "`>",
            "\\", "\\\\", "\\`", ">>>>>>>>>>", "<<<<<<<<<<", "----------",
            "`t", "`=", "`{", "`:", "`F", "`FT", "`B", "`BT", "`Fg", "`FTg",
            "<`t", "<`=", "<-", "<<>x", "`[a`b`c`d`e]", "`<a`b>c`<d`e>",
            String(repeating: "`", count: 500),
            String(repeating: "`[", count: 200),
            String(repeating: "<", count: 200),
            "`=\n`t\n`t\n`=\n`t",
        ]
        for sample in samples {
            let tokens = MicronSyntax.tokens(in: sample)
            let end = sample.utf16.count
            var previousEnd = 0
            for token in tokens {
                XCTAssertGreaterThan(token.range.length, 0, "empty token in \(sample.debugDescription)")
                XCTAssertGreaterThanOrEqual(token.range.location, previousEnd,
                                            "overlap or reorder in \(sample.debugDescription)")
                XCTAssertLessThanOrEqual(token.range.location + token.range.length, end,
                                         "out of bounds in \(sample.debugDescription)")
                previousEnd = token.range.location + token.range.length
            }
            _ = MicronLinter.diagnostics(in: sample)
        }
    }

    func testCarriageReturnsAreNotLineBreaks() {
        // Faithfulness, not politeness: "\r\n" is a single grapheme cluster, so
        // `split(separator: "\n")` in MicronParser does not break on it and the
        // whole CRLF document is one line. A lexer that split on CRLF would
        // highlight lines the renderer never produces.
        assertTokens("# c\r\n`!", [(.comment, 0, 7)])
    }

    // MARK: - Lints

    func testUnterminatedLiteralMode() {
        let diagnostics = MicronLinter.diagnostics(in: "intro\n`=\nverbatim")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .error)
        XCTAssertEqual(diagnostics[0].line, 2)
        XCTAssertEqual(diagnostics[0].range, NSRange(location: 6, length: 2))
        XCTAssertTrue(diagnostics[0].message.contains("never closed"))
        XCTAssertTrue(diagnostics[0].message.contains("`="))
    }

    func testTerminatedLiteralModeIsClean() {
        XCTAssertTrue(MicronLinter.diagnostics(in: "`=\nverbatim\n`=").isEmpty)
    }

    func testUnterminatedTableMode() {
        let diagnostics = MicronLinter.diagnostics(in: "`tc\nA | B")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .error)
        XCTAssertEqual(diagnostics[0].line, 1)
        XCTAssertEqual(diagnostics[0].range, NSRange(location: 0, length: 3))
        XCTAssertTrue(diagnostics[0].message.contains("table row"))
    }

    func testTerminatedTableModeIsClean() {
        XCTAssertTrue(MicronLinter.diagnostics(in: "`t\nA | B\n`t").isEmpty)
    }

    func testUnknownCommandLint() {
        let diagnostics = MicronLinter.diagnostics(in: "hello `Q world")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .warning)
        XCTAssertEqual(diagnostics[0].range, NSRange(location: 6, length: 2))
        XCTAssertTrue(diagnostics[0].message.contains("`Q"))
        XCTAssertTrue(diagnostics[0].message.contains("deletes"))
    }

    func testKnownCommandsDoNotLint() {
        XCTAssertTrue(MicronLinter.diagnostics(in: "`!x`!`_y`_`*z`*`c`l`r`a`f`b``").isEmpty)
    }

    func testTrailingBacktickLint() {
        let diagnostics = MicronLinter.diagnostics(in: "end`")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].range, NSRange(location: 3, length: 1))
        XCTAssertTrue(diagnostics[0].message.contains("Trailing"))
    }

    func testMalformedLinkLints() {
        let unclosed = MicronLinter.diagnostics(in: "see `[/page/x")
        XCTAssertEqual(unclosed.count, 1)
        XCTAssertEqual(unclosed[0].severity, .error)
        XCTAssertEqual(unclosed[0].range, NSRange(location: 4, length: 2))
        XCTAssertTrue(unclosed[0].message.contains("closing ]"))

        // Two diagnostics: the dead link, then the "`]" the rescan turns into an
        // unknown command.
        let empty = MicronLinter.diagnostics(in: "`[label`]")
        XCTAssertEqual(empty.count, 2)
        XCTAssertEqual(empty[0].severity, .error)
        // The diagnostic spans the whole attempted link even though only the
        // "`[" is consumed.
        XCTAssertEqual(empty[0].range, NSRange(location: 0, length: 9))
        XCTAssertTrue(empty[0].message.contains("no URL"))
        XCTAssertTrue(empty[1].message.contains("`]"))
    }

    func testWellFormedLinksDoNotLint() {
        XCTAssertTrue(MicronLinter.diagnostics(in: "`[url]\n`[Label`url]\n`[L`u`a|b]").isEmpty)
    }

    func testMalformedFieldLints() {
        let noBacktick = MicronLinter.diagnostics(in: "`<name>")
        XCTAssertEqual(noBacktick.count, 1)
        XCTAssertEqual(noBacktick[0].severity, .error)
        XCTAssertEqual(noBacktick[0].range, NSRange(location: 0, length: 2))
        XCTAssertTrue(noBacktick[0].message.contains("no ` separator"))

        let unclosed = MicronLinter.diagnostics(in: "`<name`data")
        XCTAssertEqual(unclosed.count, 2)
        XCTAssertTrue(unclosed[0].message.contains("closing >"))
        XCTAssertTrue(unclosed[1].message.contains("`d"))
    }

    func testWellFormedFieldDoesNotLint() {
        XCTAssertTrue(MicronLinter.diagnostics(in: "`<32|name`value>").isEmpty)
    }

    func testBadColourLints() {
        let threeDigit = MicronLinter.diagnostics(in: "`Fzzz")
        XCTAssertEqual(threeDigit.count, 1)
        XCTAssertEqual(threeDigit[0].severity, .warning)
        XCTAssertEqual(threeDigit[0].range, NSRange(location: 0, length: 5))
        XCTAssertTrue(threeDigit[0].message.contains("default colour"))

        let sixDigit = MicronLinter.diagnostics(in: "`BT00gg00")
        XCTAssertEqual(sixDigit.count, 1)
        XCTAssertEqual(sixDigit[0].range, NSRange(location: 0, length: 9))

        let truncated = MicronLinter.diagnostics(in: "`F12")
        XCTAssertEqual(truncated.count, 1)
        XCTAssertEqual(truncated[0].range, NSRange(location: 0, length: 2))
        XCTAssertTrue(truncated[0].message.contains("too few"))
    }

    func testGoodColoursDoNotLint() {
        XCTAssertTrue(MicronLinter.diagnostics(in: "`F00f`FT00ff00`B0a0`BT112233`Fg50`f`b").isEmpty)
    }

    func testOpenStyleToggleLints() {
        let diagnostics = MicronLinter.diagnostics(in: "start\n`!bold to the end")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .warning)
        XCTAssertEqual(diagnostics[0].line, 2)
        XCTAssertEqual(diagnostics[0].range, NSRange(location: 6, length: 2))
        XCTAssertTrue(diagnostics[0].message.contains("bold"))
    }

    func testBalancedStyleTogglesDoNotLint() {
        XCTAssertTrue(MicronLinter.diagnostics(in: "`!bold`! `_u`_ `*i`*").isEmpty)
    }

    func testResetTagClosesEveryOpenStyle() {
        XCTAssertTrue(MicronLinter.diagnostics(in: "`!`_`*all on``").isEmpty)
    }

    func testStyleTogglesInsideLiteralAndTableBodiesAreNotState() {
        XCTAssertTrue(MicronLinter.diagnostics(in: "`=\n`!\n`=").isEmpty)
        XCTAssertTrue(MicronLinter.diagnostics(in: "`t\n`!\n`t").isEmpty)
    }

    func testEveryUnclosedStyleIsReportedSeparately() {
        let diagnostics = MicronLinter.diagnostics(in: "`!`_`*")
        XCTAssertEqual(diagnostics.count, 3)
        XCTAssertEqual(diagnostics.map(\.range.location), [0, 2, 4])
        XCTAssertTrue(diagnostics[0].message.contains("bold"))
        XCTAssertTrue(diagnostics[1].message.contains("underline"))
        XCTAssertTrue(diagnostics[2].message.contains("italic"))
    }

    func testHeadingTooDeepLints() {
        let diagnostics = MicronLinter.diagnostics(in: ">>>>Deep")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .warning)
        XCTAssertEqual(diagnostics[0].range, NSRange(location: 0, length: 4))
        XCTAssertTrue(diagnostics[0].message.contains("Heading depth 4"))
    }

    func testHeadingsUpToThreeDoNotLint() {
        XCTAssertTrue(MicronLinter.diagnostics(in: ">One\n>>Two\n>>>Three").isEmpty)
    }

    func testDiagnosticsAreSortedByOffset() {
        let diagnostics = MicronLinter.diagnostics(in: ">>>>Deep\n`Q\n`<name>\n`Fzzz")
        XCTAssertEqual(diagnostics.map(\.line), [1, 2, 3, 4])
        XCTAssertEqual(
            diagnostics.map(\.range.location).sorted(),
            diagnostics.map(\.range.location)
        )
    }

    func testRealisticPageIsClean() {
        let page = """
        # index.mu for a node
        >Welcome
        `c`!RetiOS`!`a

        -
        Body text with a `[link`:/page/other.mu] and a `Fg50grey`f word.

        `t
        Key | Value
        `t

        `=
        `!this is not bold`!
        `=

        `<32|callsign`>
        `[Send`:/page/form.mu`callsign]
        """
        XCTAssertTrue(
            MicronLinter.diagnostics(in: page).isEmpty,
            "unexpected: \(messages(page))"
        )
        XCTAssertFalse(MicronSyntax.tokens(in: page).isEmpty)
    }
}
