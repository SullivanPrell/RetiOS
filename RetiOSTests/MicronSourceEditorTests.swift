import XCTest
@testable import RetiOS

/// Locks down the *tinting policy* of the Micron source editor.
///
/// Not a rendering test — the surface itself is a `UIViewRepresentable` on iOS
/// and a `TextEditor` on macOS, neither of which is meaningfully assertable in
/// a unit test. What is worth pinning is the design rule behind the colour,
/// because it is the one thing that silently degrades: every time a new token
/// kind is added to `MicronTokenKind`, the tempting move is to give it a tint,
/// and the failure mode of "tint everything" is a page where the majority of
/// glyphs sit on a coloured band and prose stops being readable.
///
/// So: prose kinds must stay untinted, control kinds must not, and the switch
/// must remain exhaustive over the whole enum.
final class MicronSourceEditorTests: XCTestCase {

    /// The kinds that carry the reader's actual text. These must never get a
    /// background tint — see the comment on `micronTintRole`.
    private let proseKinds: [MicronTokenKind] = [
        .literalBody, .tableBody,
        .headingMarker, .headingText,
        .linkLabel, .linkURL, .linkField,
        .fieldDescriptor, .fieldData
    ]

    func testProseKindsAreNotTinted() {
        for kind in proseKinds {
            XCTAssertNil(kind.micronTintRole,
                         "\(kind.rawValue) carries page text and must stay untinted")
        }
    }

    func testControlKindsAreTinted() {
        let control: [MicronTokenKind] = [
            .styleTag, .colorTag, .alignTag, .resetTag,
            .sectionReset, .divider, .literalFence, .tableFence
        ]
        for kind in control {
            XCTAssertEqual(kind.micronTintRole, .control, "\(kind.rawValue)")
        }
    }

    func testDelimitersGetTheStrongerTint() {
        // Distinct from `.control` on purpose: a one-character delimiter at the
        // control alpha is invisible next to a full-width divider.
        XCTAssertEqual(MicronTokenKind.linkDelimiter.micronTintRole, .delimiter)
        XCTAssertEqual(MicronTokenKind.fieldDelimiter.micronTintRole, .delimiter)
    }

    func testReferencesAndProblemsAreDistinct() {
        XCTAssertEqual(MicronTokenKind.anchor.micronTintRole, .reference)
        XCTAssertEqual(MicronTokenKind.partial.micronTintRole, .reference)
        XCTAssertEqual(MicronTokenKind.unknownCommand.micronTintRole, .problem)
        XCTAssertNotEqual(MicronTokenKind.unknownCommand.micronTintRole,
                          MicronTokenKind.anchor.micronTintRole,
                          "a lexer failure must not read as a valid reference")
    }

    func testNonRenderedKindsShareTheNeutralTint() {
        XCTAssertEqual(MicronTokenKind.comment.micronTintRole, .nonContent)
        XCTAssertEqual(MicronTokenKind.escape.micronTintRole, .nonContent)
    }

    /// A guard against the enum growing past the policy. `micronTintRole`
    /// switches exhaustively with no `default:`, so a new kind is a compile
    /// error there — but only if this assertion keeps someone from "fixing"
    /// that by adding one.
    func testEveryKindHasADeliberateDecision() {
        let tinted = MicronTokenKind.allCases.filter { $0.micronTintRole != nil }
        let untinted = MicronTokenKind.allCases.filter { $0.micronTintRole == nil }
        XCTAssertFalse(tinted.isEmpty, "nothing tinted — markup would be invisible")
        XCTAssertFalse(untinted.isEmpty, "everything tinted — prose would be unreadable")
        // Pin the actual policy rather than a count ratio. The first version
        // of this asserted `tinted.count + untinted.count == allCases.count`,
        // which the two arrays satisfy by construction — it could not fail. A
        // ratio bound is not much better: it has no principled threshold, and
        // adding one legitimately-tinted kind tripped it. What actually matters
        // is WHICH kinds are prose, so name them.
        let mustStayPlain: Set<MicronTokenKind> = [
            .literalBody, .tableBody, .headingMarker, .headingText,
            .linkLabel, .linkURL, .linkField, .fieldDescriptor, .fieldData,
        ]
        for kind in mustStayPlain {
            XCTAssertNil(kind.micronTintRole,
                         "\(kind.rawValue) is prose or prose-adjacent — tinting it puts most "
                         + "of a page on a coloured band")
        }
        XCTAssertEqual(Set(untinted), mustStayPlain,
                       "the untinted set changed; update mustStayPlain deliberately")
    }
}
