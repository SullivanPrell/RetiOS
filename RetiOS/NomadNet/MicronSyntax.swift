import Foundation

/// A source-range lexer and linter for Micron markup.
///
/// `NomadNet.MicronParser.parse` already understands Micron perfectly well, but it
/// returns `[MicronNode]` and **no node carries a source offset**. An editor needs
/// the opposite of an AST: it needs to know that *these UTF-16 units* are a link
/// URL. So this file re-walks the same grammar and emits ranges instead of nodes.
///
/// That makes it a second implementation of one grammar, which is a maintenance
/// hazard — so every non-obvious branch below cites the exact behaviour in
/// `MicronParser.swift` it is mirroring. When the parser changes, these comments
/// are the diff list.
///
/// Two things worth knowing before reading further:
///
/// 1. **The parser's header doc is wrong about the escape prefix.** It claims a
///    leading `\` makes "the remainder rendered literally (no further markup)".
///    It does not: `makeOutput` starts with `var escape = preEscape`, and the
///    very first character processed clears `escape` whatever it is. So a leading
///    backslash escapes exactly *one* character — the first — and the rest of the
///    line is parsed for tags as normal.
///
/// 2. **Only literal mode and table mode change tokenization.** The style
///    toggles (bold/italic/underline/colour/alignment) bleed across lines, but
///    they never affect what is or isn't a token, so this lexer ignores them
///    entirely. `MicronLinter` runs its own tiny pass for the one rule that does
///    need them (a toggle left open at EOF).

// MARK: - Tokens

/// Lexical classes an editor cares about. Deliberately *not* a mirror of
/// `MicronNode` — these are ranges to colour, not semantics to render.
///
/// Note there is no `text` case: ordinary body text produces no token at all.
/// `headingText` exists only because heading content is worth colouring as a
/// unit, and heading content is itself tag-parsed (`parseLine` runs it through
/// `makeOutput`), so it arrives as runs interleaved with real tags.
enum MicronTokenKind: String, CaseIterable, Sendable {
    case comment, escape
    case literalFence, literalBody
    case tableFence, tableBody
    case headingMarker, headingText
    case sectionReset, divider
    case styleTag, colorTag, alignTag, resetTag
    case anchor, partial
    case linkDelimiter, linkLabel, linkURL, linkField
    case fieldDelimiter, fieldDescriptor, fieldData
    case unknownCommand
    /// A ">" run on a line that also contains a form field. The parser drops it
    /// and renders the line as body text, so it is markup the author wrote that
    /// produces nothing — distinct from `headingMarker`, which does work.
    case droppedHeadingMarker
}

struct MicronToken: Equatable, Sendable {
    /// UTF-16 offsets into the *whole* document, so this drops straight into
    /// `NSAttributedString` / `NSTextStorage` without re-basing.
    let range: NSRange
    let kind: MicronTokenKind
}

enum MicronSyntax {
    /// Tokenize a whole Micron document. Never throws, never loops: every branch
    /// of the scanner advances at least one character.
    static func tokens(in text: String) -> [MicronToken] {
        MicronScanner.scan(text, collectDiagnostics: false).tokens
    }
}

// MARK: - Diagnostics

struct MicronDiagnostic: Equatable, Sendable {
    enum Severity: String, Sendable { case warning, error }
    let range: NSRange
    let line: Int          // 1-based
    let severity: Severity
    let message: String
}

/// A small, opinionated set of lints. The bar for inclusion is that the parser
/// *silently* does something other than what the author wrote — Micron has no
/// error reporting of its own, so a mistyped tag just vanishes from the page and
/// the author is left staring at a hole. Each message therefore says what will
/// happen, not merely that something is wrong.
///
/// Severity is `error` when author content is discarded or swallowed, `warning`
/// when only the tag itself is lost or degraded.
enum MicronLinter {
    static func diagnostics(in text: String) -> [MicronDiagnostic] {
        let result = MicronScanner.scan(text, collectDiagnostics: true)
        var diagnostics = result.diagnostics
        diagnostics.append(contentsOf: openStyleDiagnostics(in: text, result: result))

        // `sort` is not stable, so a bare `location <` comparison could reorder
        // two diagnostics that share an offset between runs and make assertions
        // flaky. Break the tie on the message.
        return diagnostics.sorted {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.message < $1.message
        }
    }

    /// The one rule that needs formatting state the lexer deliberately throws away.
    ///
    /// `ParseState.bold/underline/italic` are toggles that persist across lines
    /// for the whole document — nothing resets them at end of line, end of
    /// section or end of heading. Only `` `` `` (`resetFormatting`) clears them.
    /// So an unmatched `` `! `` doesn't bold a word, it bolds the rest of the page.
    private static func openStyleDiagnostics(
        in text: String,
        result: MicronScanner.Result
    ) -> [MicronDiagnostic] {

        // command character → (human name, range of the toggle that opened it)
        var open: [Character: NSRange] = [:]

        for token in result.tokens {
            switch token.kind {
            case .styleTag:
                guard let range = Range(token.range, in: text) else { continue }
                // Two ASCII characters: the backtick and the command.
                let command = text[range].last ?? " "
                if open.removeValue(forKey: command) == nil {
                    open[command] = token.range
                }
            case .resetTag:
                open.removeAll()
            default:
                break
            }
        }

        return open.map { command, range in
            MicronDiagnostic(
                range: range,
                line: result.line(containing: range.location),
                severity: .warning,
                message: "`\(command) (\(styleName(command))) is never turned off — "
                    + "the toggle persists to the end of the document. "
                    + "Add a matching `\(command) or a `` reset."
            )
        }
    }

    private static func styleName(_ command: Character) -> String {
        switch command {
        case "!": return "bold"
        case "_": return "underline"
        case "*": return "italic"
        default:  return "style"
        }
    }
}

// MARK: - Scanner

/// The single state machine behind both `MicronSyntax.tokens` and
/// `MicronLinter.diagnostics`. They must agree — a token stream that says
/// "field" where the linter says "not a field" is worse than either alone — so
/// there is exactly one walk of the document and the two public entry points are
/// thin projections of its result.
private struct MicronScanner {

    struct Result {
        var tokens: [MicronToken] = []
        var diagnostics: [MicronDiagnostic] = []
        /// UTF-16 offset of the first character of each line; index n-1 is line n.
        var lineStarts: [Int] = []

        /// 1-based line containing a UTF-16 offset.
        func line(containing offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low + 1
        }
    }

    /// Characters, not UTF-16 units: the parser indexes `Array(line)` and its
    /// bounds checks (`i + 7 < line.count`) are in those units, so any other
    /// indexing would silently disagree with it on non-ASCII input.
    private let chars: [Character]
    /// `offsets[i]` is the UTF-16 offset of `chars[i]`; `offsets[count]` is the end.
    /// This is what keeps an emoji earlier in the document from shifting every
    /// range after it.
    private let offsets: [Int]
    /// Diagnostic messages are string interpolation on a hot path (`tokens(in:)`
    /// runs on every keystroke), so they are `@autoclosure`d behind this flag.
    private let collectDiagnostics: Bool

    private var out = Result()
    private var lineNumber = 1

    // The only two states that change tokenization.
    private var literal = false
    private var table = false
    /// Where the currently open fence was opened, for the "never closed" lints.
    private var literalFence: (range: NSRange, line: Int)?
    private var tableFence: (range: NSRange, line: Int)?

    static func scan(_ text: String, collectDiagnostics: Bool) -> Result {
        var scanner = MicronScanner(text: text, collectDiagnostics: collectDiagnostics)
        scanner.run()
        return scanner.out
    }

    private init(text: String, collectDiagnostics: Bool) {
        let characters = Array(text)
        var offsets = [Int]()
        offsets.reserveCapacity(characters.count + 1)
        var utf16Offset = 0
        for character in characters {
            offsets.append(utf16Offset)
            utf16Offset += character.utf16.count
        }
        offsets.append(utf16Offset)
        self.chars = characters
        self.offsets = offsets
        self.collectDiagnostics = collectDiagnostics
    }

    // MARK: Document

    private mutating func run() {
        // Line splitting matches `MicronParser.parse`, which does
        // `split(separator: "\n", omittingEmptySubsequences: false)` over
        // *Characters*. Trap: "\r\n" is a single grapheme cluster and is not
        // equal to "\n", so a CRLF document is one enormous line to the parser
        // — and therefore to us. Reproducing that is the point; a lexer that
        // helpfully split on CRLF would highlight lines the renderer never sees.
        var lineStart = 0
        var index = 0
        while index <= chars.count {
            if index == chars.count || chars[index] == "\n" {
                out.lineStarts.append(offsets[lineStart])
                scanLine(lineStart, index)
                lineNumber += 1
                lineStart = index + 1
            }
            index += 1
        }

        if let fence = literalFence {
            diagnose(.error, fence.range, line: fence.line,
                     "Literal block is never closed — every line to the end of the "
                     + "document renders verbatim, tags and all. Add a closing `= line.")
        }
        if let fence = tableFence {
            // `parse()` flushes `tableBuffer` at EOF, so the rows do render — but
            // as table cells, not as markup.
            diagnose(.error, fence.range, line: fence.line,
                     "Table is never closed — every line to the end of the document "
                     + "becomes a table row. Add a closing `t line.")
        }
    }

    // MARK: Line

    /// Mirrors `MicronParser.parseLine`, in its exact order. The order is load
    /// bearing: it is why `#` is a comment even inside a table, why `` `= ``
    /// toggles literal mode even inside a table, and why an escaped `` \`t ``
    /// still toggles table mode.
    private mutating func scanLine(_ lo: Int, _ hi: Int) {
        guard lo < hi else { return }   // empty line: `parse` emits `.emptyLine` and touches no state

        // 1. Literal fence. Compared against the *whole* line, in and out of
        //    literal mode, before anything else. "`= " with a trailing space is
        //    not a fence.
        if hi - lo == 2, chars[lo] == "`", chars[lo + 1] == "=" {
            emit(.literalFence, lo, hi)
            literal.toggle()
            literalFence = literal ? (range(lo, hi), lineNumber) : nil
            return
        }

        // 2. Literal body — no tag recognition at all.
        if literal {
            emit(.literalBody, lo, hi)
            return
        }

        // 3. Comment. Checked on the raw first character, *before* the escape
        //    prefix and before table buffering.
        if chars[lo] == "#" {
            emit(.comment, lo, hi)
            return
        }

        // 4. Escape prefix / heading demotion.
        var work = lo
        var preEscape = false
        if chars[lo] == "\\" {
            emit(.escape, lo, lo + 1)
            work = lo + 1
            preEscape = true
        } else if chars[lo] == ">", containsFieldOpener(lo, hi) {
            // `parseLine`: a heading line that also contains "`<" loses heading
            // status entirely — the whole run of ">" is dropped and the rest is
            // parsed as an ordinary line.
            //
            // Worth a diagnostic even though nothing the author typed is lost:
            // the heading silently is not a heading, and the editor's own
            // palette builds this exact line (tap Heading, then Insert Field,
            // both of which append to the current line). Emitted as .nonContent
            // so the dropped ">" run is also visibly marked as not rendering.
            let markerStart = work
            while work < hi, chars[work] == ">" { work += 1 }
            if work > markerStart {
                emit(.droppedHeadingMarker, markerStart, work)
                diagnose(.warning, markerStart, work,
                         "This line contains a form field, so Micron drops the heading "
                         + "marker entirely and renders the line as body text. Put the "
                         + "field on its own line to keep the heading.")
            }
        }
        guard work < hi else { return }

        // 5. Table fence: `hasPrefix("`t")` and nothing more. The align
        //    character and width are parsed leniently (`Int(rest)` failing just
        //    means "no width"), so "`tzzz" is still a fence. Note this is
        //    checked on the *escaped* line, which is why "\`t" toggles too.
        if work + 1 < hi, chars[work] == "`", chars[work + 1] == "t" {
            emit(.tableFence, work, hi)
            table.toggle()
            tableFence = table ? (range(work, hi), lineNumber) : nil
            return
        }

        // 6. Table body.
        if table {
            emit(.tableBody, work, hi)
            return
        }

        // 7. Partial. The whole line is consumed whether or not the "}" is
        //    found (`parsePartial` returning nil still returns no nodes), so the
        //    whole line is one token.
        if work + 1 < hi, chars[work] == "`", chars[work + 1] == "{" {
            emit(.partial, work, hi)
            return
        }

        // 8. Section reset. The remainder is re-parsed *as a line*, so "<>Title"
        //    really is a reset followed by a heading, and "<`=" really does
        //    toggle literal mode. Recursion terminates because it always drops
        //    at least the "<".
        if !preEscape, chars[work] == "<" {
            emit(.sectionReset, work, work + 1)
            scanLine(work + 1, hi)
            return
        }

        // 9. Heading.
        if !preEscape, chars[work] == ">" {
            var end = work
            while end < hi, chars[end] == ">" { end += 1 }
            emit(.headingMarker, work, end)
            let level = end - work
            if level > 3 {
                diagnose(.warning, work, end,
                         "Heading depth \(level) — Micron defines only >, >> and >>>. "
                         + "Deeper markers still nest the section but render with the "
                         + "fallback heading style.")
            }
            scanInline(end, hi, escaped: false, plainKind: .headingText)
            return
        }

        // 10. Divider. Everything after the first character is consumed: "-x"
        //     takes x as the fill character, "-xyz" ignores the lot.
        if !preEscape, chars[work] == "-" {
            emit(.divider, work, hi)
            return
        }

        // 11. Ordinary line.
        scanInline(work, hi, escaped: preEscape, plainKind: nil)
    }

    /// Does this line contain a field opener? `parseLine` tests the raw line
    /// (including the ">" run) with `contains("`<")`.
    private func containsFieldOpener(_ lo: Int, _ hi: Int) -> Bool {
        var index = lo
        while index + 1 < hi {
            if chars[index] == "`", chars[index + 1] == "<" { return true }
            index += 1
        }
        return false
    }

    // MARK: Inline

    /// Mirrors `MicronParser.makeOutput`. Index arithmetic is kept identical to
    /// the parser's (`i += 7; i += 1` and friends) because the off-by-ones there
    /// are exactly what decides which characters survive into the page.
    ///
    /// - Parameters:
    ///   - escaped: initial state of `makeOutput`'s `escape` flag, i.e. the
    ///     parser's `preEscape`. Remember it survives exactly one character.
    ///   - plainKind: token kind for plain-text runs, or nil to emit none.
    private mutating func scanInline(
        _ lo: Int,
        _ hi: Int,
        escaped: Bool,
        plainKind: MicronTokenKind?
    ) {
        var escape = escaped
        var formatting = false
        var tagStart = lo          // index of the "`" that opened formatting mode
        var runStart: Int?         // start of the current plain-text run
        var index = lo

        func flushRun() {
            if let start = runStart, let kind = plainKind { emit(kind, start, index) }
            runStart = nil
        }

        while index < hi {
            let character = chars[index]

            if formatting {
                formatting = false
                switch character {
                case "!", "_", "*":
                    emit(.styleTag, tagStart, index + 1)

                case "`":
                    emit(.resetTag, tagStart, index + 1)

                case "f", "b":
                    emit(.colorTag, tagStart, index + 1)

                case "F", "B":
                    // `FT rrggbb (6 digit) else `F rgb (3 digit). The two guards
                    // are independent in the parser: "`FT12" fails the 6-digit
                    // length check and then feeds "T12" to parseColor3, which
                    // fails and yields the *default* colour rather than nothing.
                    if index + 1 < hi, chars[index + 1] == "T", index + 7 < hi {
                        let hex = String(chars[(index + 2)..<(index + 8)])
                        emit(.colorTag, tagStart, index + 8)
                        if !isHex6(hex) {
                            diagnose(.warning, tagStart, index + 8,
                                     "`\(character)T\(hex) is not a colour — six hex digits "
                                     + "expected. The parser falls back to the default colour.")
                        }
                        index += 8
                        continue
                    } else if index + 3 < hi {
                        let hex = String(chars[(index + 1)..<(index + 4)])
                        emit(.colorTag, tagStart, index + 4)
                        if !isColor3(hex) {
                            diagnose(.warning, tagStart, index + 4,
                                     "`\(character)\(hex) is not a colour — three hex digits or "
                                     + "g00-g99 expected. The parser falls back to the "
                                     + "default colour.")
                        }
                        index += 4
                        continue
                    } else {
                        // Too few characters left: the parser falls out of the
                        // switch, so the "`F" is dropped and whatever follows
                        // renders as ordinary text.
                        emit(.colorTag, tagStart, index + 1)
                        diagnose(.warning, tagStart, index + 1,
                                 "`\(character) has too few characters after it to be a colour — "
                                 + "the command is dropped and the rest renders as text.")
                    }

                case "c", "l", "r", "a":
                    emit(.alignTag, tagStart, index + 1)

                case ":":
                    // Anchor: "`:" plus [A-Za-z0-9_-]*. The parser resumes *at*
                    // the first non-name character (its `continue` skips the
                    // i += 1), so a zero-length name consumes only "`:".
                    var end = index + 1
                    while end < hi, isAnchorCharacter(chars[end]) { end += 1 }
                    emit(.anchor, tagStart, end)
                    index = end
                    continue

                case "<":
                    switch parseField(from: index + 1, to: hi) {
                    case .ok(let backtick, let closing):
                        emit(.fieldDelimiter, tagStart, index + 1)
                        emit(.fieldDescriptor, index + 1, backtick)
                        emit(.fieldDelimiter, backtick, backtick + 1)
                        emit(.fieldData, backtick + 1, closing)
                        emit(.fieldDelimiter, closing, closing + 1)
                        index = closing + 1
                        continue
                    case .missingBacktick:
                        emit(.fieldDelimiter, tagStart, index + 1)
                        diagnose(.error, tagStart, index + 1,
                                 "Field has no ` separator, so it is not a field at all — "
                                 + "the parser drops the `< and renders the rest as text. "
                                 + "Write `<name`data>.")
                    case .unclosed:
                        emit(.fieldDelimiter, tagStart, index + 1)
                        diagnose(.error, tagStart, index + 1,
                                 "Field is missing its closing > — the parser drops the `< "
                                 + "and renders the rest of the line as text.")
                    }

                case "[":
                    switch parseLink(from: index + 1, to: hi) {
                    case .ok(let separators, let end):
                        emitLinkTokens(open: tagStart, start: index + 1,
                                       separators: separators, end: end)
                        index = end + 1
                        continue
                    case .unclosed:
                        emit(.linkDelimiter, tagStart, index + 1)
                        diagnose(.error, tagStart, index + 1,
                                 "Link is missing its closing ] — the parser drops the `[ "
                                 + "and renders the rest of the line as text.")
                    case .emptyURL(let end):
                        // As with every other failed construct: only the "`["
                        // is consumed, so the brackets' contents carry on being
                        // scanned as ordinary text. The *diagnostic* spans the
                        // whole attempted link, which is what the author needs
                        // to see; the token does not.
                        emit(.linkDelimiter, tagStart, index + 1)
                        diagnose(.error, tagStart, end + 1,
                                 "Link has no URL — the parser drops the whole link, label "
                                 + "included. Write `[label`url].")
                    }

                default:
                    // Anything else after a backtick is consumed and produces
                    // nothing — both characters simply disappear from the page.
                    emit(.unknownCommand, tagStart, index + 1)
                    diagnose(.warning, tagStart, index + 1,
                             "Unknown command `\(character) — the parser deletes it silently "
                             + "and renders nothing.")
                }
            } else if character == "\\" {
                if escape {
                    // Escaped backslash: renders as a literal "\".
                    if runStart == nil { runStart = index }
                    escape = false
                } else {
                    flushRun()
                    emit(.escape, index, index + 1)
                    escape = true
                }
            } else if character == "`" {
                if escape {
                    if runStart == nil { runStart = index }
                    escape = false
                } else {
                    flushRun()
                    tagStart = index
                    formatting = true
                }
            } else {
                if runStart == nil { runStart = index }
                escape = false
            }

            index += 1
        }

        flushRun()

        if formatting {
            // A backtick as the last character of a line: `makeOutput` exits
            // still in formatting mode, so the backtick never reaches a command
            // and is dropped.
            emit(.unknownCommand, tagStart, tagStart + 1)
            diagnose(.warning, tagStart, tagStart + 1,
                     "Trailing ` with no command character after it — the parser drops it.")
        }
    }

    // MARK: Fields and links

    private enum FieldParse {
        case ok(backtick: Int, closing: Int)
        case missingBacktick
        case unclosed
    }

    /// `parseField`: the first "`" at or after the opener ends the flags|name
    /// part, and the first ">" at or after *that* backtick closes the field.
    /// Both searches run to end of line, so a field can swallow a lot.
    private func parseField(from start: Int, to hi: Int) -> FieldParse {
        guard let backtick = firstIndex(of: "`", from: start, to: hi) else { return .missingBacktick }
        guard let closing = firstIndex(of: ">", from: backtick, to: hi) else { return .unclosed }
        return .ok(backtick: backtick, closing: closing)
    }

    private enum LinkParse {
        /// `separators` are the backtick indices inside the brackets.
        case ok(separators: [Int], end: Int)
        case unclosed
        case emptyURL(end: Int)
    }

    private func parseLink(from start: Int, to hi: Int) -> LinkParse {
        guard let end = firstIndex(of: "]", from: start, to: hi) else { return .unclosed }

        var separators: [Int] = []
        var index = start
        while index < end {
            if chars[index] == "`" { separators.append(index) }
            index += 1
        }

        // `parseLink` splits on "`": with one component that component is the
        // URL (not the label), with two or more the second is. An empty URL
        // fails the `guard !url.isEmpty` and the whole link is discarded.
        let urlStart = separators.isEmpty ? start : separators[0] + 1
        let urlEnd = separators.count > 1 ? separators[1] : end
        guard urlEnd > urlStart else { return .emptyURL(end: end) }

        return .ok(separators: separators, end: end)
    }

    private mutating func emitLinkTokens(open: Int, start: Int, separators: [Int], end: Int) {
        emit(.linkDelimiter, open, start)       // "`["
        if separators.isEmpty {
            emit(.linkURL, start, end)          // single component: it is the URL
        } else {
            emit(.linkLabel, start, separators[0])
            emit(.linkDelimiter, separators[0], separators[0] + 1)
            if separators.count == 1 {
                emit(.linkURL, separators[0] + 1, end)
            } else {
                emit(.linkURL, separators[0] + 1, separators[1])
                emit(.linkDelimiter, separators[1], separators[1] + 1)
                // The parser only ever reads components[2], so a fourth
                // backtick-separated chunk is silently ignored; it is covered by
                // this one token rather than pretending it means anything.
                emit(.linkField, separators[1] + 1, end)
            }
        }
        emit(.linkDelimiter, end, end + 1)      // "]"
    }

    // MARK: Character classes

    private func isAnchorCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    /// ASCII-only, for the same reason as `isColor3`.
    private func isHex6(_ hex: String) -> Bool {
        hex.count == 6 && hex.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// `parseColor3`: "gNN" is a greyscale percentage (two *decimal* digits),
    /// anything else is three hex nibbles. Flagging "`Fg50" as a bad colour
    /// would be a false positive on perfectly good markup.
    private func isColor3(_ hex: String) -> Bool {
        let characters = Array(hex)
        guard characters.count == 3 else { return false }
        if characters[0] == "g" { return UInt8(String(characters[1...2])) != nil }
        // ASCII-only. `Character.isHexDigit` is Unicode-wide and returns true
        // for the fullwidth forms U+FF10…, which a CJK IME produces — but the
        // parser validates with `UInt8(_:radix: 16)`, which is strictly ASCII
        // and returns nil for them. Accepting them here meant a colour tag that
        // silently does nothing passed the lint as valid.
        return characters.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private func firstIndex(of character: Character, from: Int, to: Int) -> Int? {
        var index = from
        while index < to {
            if chars[index] == character { return index }
            index += 1
        }
        return nil
    }

    // MARK: Emission

    private func range(_ lo: Int, _ hi: Int) -> NSRange {
        NSRange(location: offsets[lo], length: offsets[hi] - offsets[lo])
    }

    private mutating func emit(_ kind: MicronTokenKind, _ lo: Int, _ hi: Int) {
        guard hi > lo else { return }   // zero-length tokens are noise to a highlighter
        out.tokens.append(MicronToken(range: range(lo, hi), kind: kind))
    }

    private mutating func diagnose(
        _ severity: MicronDiagnostic.Severity,
        _ lo: Int,
        _ hi: Int,
        _ message: @autoclosure () -> String
    ) {
        diagnose(severity, range(lo, hi), line: lineNumber, message())
    }

    private mutating func diagnose(
        _ severity: MicronDiagnostic.Severity,
        _ range: NSRange,
        line: Int,
        _ message: @autoclosure () -> String
    ) {
        guard collectDiagnostics else { return }
        out.diagnostics.append(
            MicronDiagnostic(range: range, line: line, severity: severity, message: message())
        )
    }
}
