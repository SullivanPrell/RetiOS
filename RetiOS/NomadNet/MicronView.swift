import SwiftUI
import NomadNet

/// Renders a parsed Micron AST ([MicronNode]) into SwiftUI views.
///
/// Form fields are rendered as interactive controls. When any link that carries
/// field references is tapped, `onLinkTapped` is called with both the link and
/// the current form values dictionary keyed by field name.
struct MicronView: View {
    let nodes: [MicronNode]
    /// Called when a link is tapped. Second argument is the current form state
    /// (field-name → value); empty when the page has no form fields.
    var onLinkTapped: ((MicronLink, [String: String]) -> Void)?

    @State private var formValues: [String: String] = [:]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                MicronNodeView(
                    node: node,
                    formValues: $formValues,
                    onLinkTapped: { link in onLinkTapped?(link, formValues) }
                )
            }
        }
        .onAppear { resetFormDefaults(from: nodes) }
        .onChange(of: nodes) { _, newNodes in
            formValues = [:]
            resetFormDefaults(from: newNodes)
        }
    }

    /// Scan all field spans in the AST and populate `formValues` with their
    /// default (pre-filled) values for any key not already present.
    private func resetFormDefaults(from nodes: [MicronNode]) {
        for node in nodes {
            let spans: [MicronSpan]
            switch node {
            case .line(let s, _, _):          spans = s
            case .heading(_, let s, _, _):    spans = s
            default:                           spans = []
            }
            for span in spans {
                if case .field(let f) = span, formValues[f.name] == nil {
                    switch f.fieldType {
                    case .checkbox: formValues[f.name] = f.prechecked ? "true" : "false"
                    case .radio:    if f.prechecked { formValues[f.name] = f.value }
                    default:        formValues[f.name] = f.value
                    }
                }
            }
        }
    }
}

// MARK: - Node

private struct MicronNodeView: View {
    let node: MicronNode
    @Binding var formValues: [String: String]
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        switch node {
        case .emptyLine:
            Spacer().frame(height: 8)

        case .line(let spans, _, let alignment):
            MicronSpansView(spans: spans, alignment: alignment,
                            formValues: $formValues, onLinkTapped: onLinkTapped)

        case .heading(let level, let spans, _, _):
            MicronSpansView(spans: spans, alignment: .left,
                            formValues: $formValues, onLinkTapped: onLinkTapped)
                .font(headingFont(level: level))

        case .horizontalRule:
            Divider()
                .padding(.vertical, 4)

        case .table(let rows, _, _):
            MicronTableView(rows: rows)

        case .partial(let partial):
            MicronPartialView(partial: partial, onLinkTapped: onLinkTapped)

        case .anchor:
            EmptyView()
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        default: return .headline
        }
    }
}

// MARK: - Spans

private struct MicronSpansView: View {
    let spans: [MicronSpan]
    let alignment: MicronAlignment
    @Binding var formValues: [String: String]
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                MicronSpanView(span: span, formValues: $formValues, onLinkTapped: onLinkTapped)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: swiftAlignment)
    }

    private var swiftAlignment: Alignment {
        switch alignment {
        case .left:   return .leading
        case .center: return .center
        case .right:  return .trailing
        }
    }
}

// MARK: - Span

private struct MicronSpanView: View {
    let span: MicronSpan
    @Binding var formValues: [String: String]
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        switch span {
        case .text(let str, let style):
            styledText(str, style: style)
        case .link(let link):
            Button(action: { onLinkTapped?(link) }) {
                styledText(link.label.isEmpty ? link.url : link.label, style: link.style)
                    .foregroundColor(.blue)
                    .underline()
            }
            .buttonStyle(.plain)
        case .field(let field):
            MicronFieldView(field: field, formValues: $formValues)
        }
    }

    private func styledText(_ content: String, style: MicronStyle) -> Text {
        var t = Text(content)
        if style.bold        { t = t.bold() }
        if style.italic      { t = t.italic() }
        if style.underline   { t = t.underline() }
        if style.strikethrough { t = t.strikethrough() }
        if style.fgColor != .default {
            t = t.foregroundColor(micronColor(style.fgColor))
        }
        return t
    }

    private func micronColor(_ c: MicronColor) -> Color {
        switch c {
        case .default:        return .primary
        case .rgb3(let r, let g, let b):
            return Color(red: Double(r) / 3, green: Double(g) / 3, blue: Double(b) / 3)
        case .rgb6(let r, let g, let b):
            return Color(red: Double(r) / 5, green: Double(g) / 5, blue: Double(b) / 5)
        case .grey(let pct):
            let v = Double(pct) / 100
            return Color(white: v)
        }
    }
}

// MARK: - Field

/// Renders a Micron form field as an interactive SwiftUI control.
///
/// - `.text` / `.masked` → `TextField` / `SecureField` with configurable width
/// - `.checkbox`         → `Toggle` bound to "true"/"false" string in formValues
/// - `.radio`            → button that sets formValues[name] = field.value when tapped
private struct MicronFieldView: View {
    let field: MicronField
    @Binding var formValues: [String: String]

    var body: some View {
        switch field.fieldType {
        case .text:
            TextField(placeholder, text: textBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: fieldWidth)
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                .rnsNoAutocapitalization()

        case .masked:
            SecureField(placeholder, text: textBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: fieldWidth)
                .font(.caption.monospaced())

        case .checkbox:
            Toggle(isOn: boolBinding) {
                if !field.label.isEmpty {
                    Text(field.label).font(.caption)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel(field.label.isEmpty ? field.name : field.label)

        case .radio:
            Button(action: { formValues[field.name] = field.value }) {
                HStack(spacing: 4) {
                    Image(systemName: isRadioSelected ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(isRadioSelected ? Color.rnsAccent : .secondary)
                    if !field.label.isEmpty {
                        Text(field.label)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(field.label.isEmpty ? field.name : field.label)
            .accessibilityAddTraits(isRadioSelected ? .isSelected : [])
        }
    }

    // MARK: Computed

    private var placeholder: String { field.label.isEmpty ? field.name : field.label }

    /// Translate the `width` column-count to a SwiftUI point width.
    /// Assumes monospaced character ≈ 8 pt wide; clamp to [64, 320].
    private var fieldWidth: CGFloat {
        CGFloat(max(8, field.width)) * 8
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { formValues[field.name] ?? field.value },
            set: { formValues[field.name] = $0 }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: {
                let stored = formValues[field.name]
                return stored == "true" || (stored == nil && field.prechecked)
            },
            set: { formValues[field.name] = $0 ? "true" : "false" }
        )
    }

    private var isRadioSelected: Bool {
        formValues[field.name] == field.value
    }
}

// MARK: - Table

private struct MicronTableView: View {
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 2)
                if idx == 0 { Divider() }
            }
        }
    }
}

// MARK: - Partial

private struct MicronPartialView: View {
    let partial: MicronPartial
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        let link = MicronLink(label: partial.url, url: partial.url)
        Button(action: { onLinkTapped?(link) }) {
            Label(partial.url, systemImage: "arrow.right.square")
                .font(.caption.monospaced())
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }
}
