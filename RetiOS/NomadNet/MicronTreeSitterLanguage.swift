#if os(iOS)
import Runestone
import TreeSitterMicron

extension TreeSitterLanguage {
    static var micron: TreeSitterLanguage {
        TreeSitterLanguage(tree_sitter_micron(), highlightsQuery: .init(string: highlightsQuerySource))
    }
}

// Mirrors tree-sitter-micron's queries/highlights.scm verbatim. Not loaded as a
// bundled resource: TreeSitterMicron is a pure C target (no Swift/Obj-C
// sources), which never gets a synthesized `Bundle.module` accessor, so there
// is no supported way to read a copied resource file from it. Keep this in
// sync BY HAND when that file changes — it rarely does.
private let highlightsQuerySource = """
(comment) @comment

(config_key) @property
(config_value) @string

(heading_marker) @punctuation.special
(heading_content) @markup.heading
(section_reset) @punctuation.special

(divider) @punctuation.special

(format_bold) @markup.bold
(format_italic) @markup.italic
(format_underline) @markup.underline
(format_reset) @function.builtin

(align_center) @keyword
(align_left) @keyword
(align_right) @keyword
(align_reset) @keyword

(fg_color) @function.builtin
(fg_color_true) @function.builtin
(fg_reset) @function.builtin
(bg_color) @function.builtin
(bg_color_true) @function.builtin
(bg_reset) @function.builtin
(color_value) @constant.numeric

(link) @markup.link
(link_label) @markup.link.label
(link_url) @markup.link.url
(link_fields) @string

(field_flags) @attribute
(field_name) @variable
(field_value) @string
(field_prechecked) @constant.builtin
(field_data) @string

(anchor_name) @label

(escape_sequence) @string.escape

(literal_content) @markup.raw.block
(table_content) @markup.raw.block

(partial_url) @markup.link.url
(partial_refresh) @number
(partial_fields) @string
"""
#endif
