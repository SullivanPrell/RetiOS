import Foundation

// Pure markup construction for the editor's builder sheets.
//
// Split out of the sheets themselves so it can be tested. As `@State private`
// fields inside a `View` this logic was unreachable from a test, and it is
// exactly the logic worth testing: the sheets emit markup on the user's behalf,
// so a mistake here is a mistake in every page anyone writes with them. Two real
// bugs were found by testing these — a link form Python NomadNet rejects
// outright, and values that truncate the construct they sit in.
//
// Both types are value types with defaults, so a caller builds one, sets what it
// needs, and reads `snippet`.

// MARK: - Link

/// Builds `` `[label`url`fields] ``.
struct MicronLinkSnippet: Equatable {
    enum Kind: String, CaseIterable, Equatable {
        case page, anchor, node

        var title: String {
            switch self {
            case .page:   return "Page on this node"
            case .anchor: return "Anchor in this page"
            case .node:   return "Another node"
            }
        }

        var prompt: String {
            switch self {
            case .page:   return "/page/about.mu"
            case .anchor: return "section-name"
            case .node:   return "a1b2…:/page/index.mu"
            }
        }
    }

    var kind: Kind = .page
    var target: String = ""
    var label: String = ""

    /// `]` closes the link at the FIRST occurrence and a backtick starts a new
    /// component, so either one silently truncates the link into something the
    /// author did not write.
    static let forbidden: Set<Character> = ["]", "`"]

    var url: String {
        switch kind {
        case .page:
            // The leading ":" is required, not cosmetic. Python NomadNet's
            // `Browser.retrieve_url` splits the URL on ":" and, given a single
            // component, demands exactly 32 hex characters — so a bare
            // "/page/about.mu" raises ValueError("Malformed URL") for every
            // Python peer. ":/page/about.mu" takes the empty-first-component
            // branch, which resolves against the node being browsed.
            //
            // RetiOS's own browser handles both forms (see
            // NomadNetBrowserView.handleLink), so the bare form looked fine in
            // the preview pane and was broken only for everyone else.
            let path = target.hasPrefix("/") ? target : "/" + target
            return ":" + path
        case .anchor:
            return "#" + target
        case .node:
            return target
        }
    }

    var snippet: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "`[\(url)]" : "`[\(trimmed)`\(url)]"
    }

    /// Characters present in the inputs that would corrupt the link.
    var offendingCharacters: [Character] {
        Array(Set((label + target).filter { Self.forbidden.contains($0) })).sorted()
    }

    var isUsable: Bool {
        !target.trimmingCharacters(in: .whitespaces).isEmpty && offendingCharacters.isEmpty
    }
}

// MARK: - Field

/// Builds `` `<flags|name|value|*`data> ``.
///
/// The flags segment carries an optional type marker (`^` radio, `?` checkbox,
/// `!` masked — MicronParser tests them in that order and the first match wins)
/// followed by an optional integer width, capped at 256 and defaulting to 24. A
/// fourth `*` component pre-checks a checkbox. The backtick before the data is
/// mandatory: without it MicronParser produces no field at all.
struct MicronFieldSnippet: Equatable {
    enum Kind: String, CaseIterable, Equatable {
        case text, masked, checkbox, radio

        var title: String {
            switch self {
            case .text:     return "Text"
            case .masked:   return "Masked"
            case .checkbox: return "Checkbox"
            case .radio:    return "Radio"
            }
        }

        /// The flag character MicronParser looks for, if any.
        var flag: String {
            switch self {
            case .text:     return ""
            case .masked:   return "!"
            case .checkbox: return "?"
            case .radio:    return "^"
            }
        }

        var usesValue: Bool { self == .checkbox || self == .radio }
    }

    var kind: Kind = .text
    var name: String = ""
    var value: String = ""
    var data: String = ""
    var width: Int = 24
    var useWidth: Bool = false
    var prechecked: Bool = false

    /// `>` closes the field at the first occurrence, a backtick separates the
    /// descriptor from the data, and `|` splits the descriptor into its
    /// segments. Any of them inside a value truncates the field and spills the
    /// remainder into the page as body text.
    static let forbiddenInName: Set<Character> = [">", "`", "|"]
    static let forbiddenInValue: Set<Character> = [">", "`"]

    var snippet: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        var flags = kind.flag
        if useWidth && !kind.usesValue { flags += String(min(width, 256)) }

        var parts: [String]
        if flags.isEmpty && !kind.usesValue && value.isEmpty {
            // Nothing to qualify, so the whole descriptor is just the name —
            // the form NomadNet's own guide uses for a plain text input.
            parts = [trimmed]
        } else {
            parts = [flags, trimmed]
            if kind.usesValue || !value.isEmpty { parts.append(value) }
            if prechecked && kind == .checkbox { parts.append("*") }
        }
        return "`<" + parts.joined(separator: "|") + "`" + data + ">"
    }

    var offendingCharacters: [Character] {
        let bad = Set(name.filter { Self.forbiddenInName.contains($0) })
            .union((value + data).filter { Self.forbiddenInValue.contains($0) })
        return Array(bad).sorted()
    }

    var isUsable: Bool { !snippet.isEmpty && offendingCharacters.isEmpty }
}
