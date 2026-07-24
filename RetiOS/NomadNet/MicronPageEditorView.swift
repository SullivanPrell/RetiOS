#if os(iOS)

import SwiftUI
import NomadNet

// The Micron page editor: source on one side, the app's real renderer on the
// other.
//
// iOS/iPadOS only, because `MicronSourceEditor` is — it wraps Runestone, which
// is UIKit-only. See the header of MicronSourceEditor.swift for the full
// constraint and for what a Mac version would take.
//
// The preview is deliberately `MicronView(nodes: MicronParser.parse(text))` —
// the exact call the Browse tab makes (NomadNetBrowserView.pageContent). Any
// other preview would be a second renderer that could disagree with what a peer
// sees, which is the one thing a page author cannot tolerate. MicronParser is
// non-throwing and degrades silently on malformed input, so it is safe to run
// against a half-typed document.
struct MicronPageEditorView: View {
    let page: MicronPage

    @Environment(MicronPageStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// Longest a keystroke may sit unwritten while the user keeps typing.
    private static let maxDebounce: TimeInterval = 5

    @State private var text = ""
    @State private var loaded = false
    /// Last text known to match the file on disk. `nil` means "nothing safe to
    /// compare against", which is also the state after a failed read.
    @State private var savedText: String?
    @State private var loadFailed = false
    @State private var firstUnsavedEdit: Date?
    @State private var mode: EditorMode = .edit
    @State private var previewWidth: PreviewWidth = .fit
    @State private var showLinkBuilder = false
    @State private var showFieldBuilder = false
    @State private var showDiagnostics = false
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

    enum EditorMode: String, CaseIterable, Hashable {
        case edit, split, preview
        var label: String {
            switch self {
            case .edit:    return "Edit"
            case .split:   return "Split"
            case .preview: return "Preview"
            }
        }
    }

    /// Micron is a terminal markup — NomadNet renders it into a fixed-width
    /// pane. Previewing at the device width alone tells the author nothing about
    /// how the page reads where it is actually read.
    enum PreviewWidth: String, CaseIterable, Hashable {
        case fit, cols80 = "80", cols132 = "132"
        var label: String { self == .fit ? "Fit" : rawValue + " cols" }
        var points: CGFloat? {
            switch self {
            case .fit:     return nil
            case .cols80:  return 80 * 7.2   // ~7.2pt per glyph at body monospace
            case .cols132: return 132 * 7.2
            }
        }
    }

    // Re-lexing and re-linting on every keystroke is fine at page scale — a
    // Micron page is a document a human wrote, not a log file. Both passes are
    // linear over the text.
    private var tokens: [MicronToken] { MicronSyntax.tokens(in: text) }
    private var diagnostics: [MicronDiagnostic] { MicronLinter.diagnostics(in: text) }

    var body: some View {
        Group {
            if loaded {
                content
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .rnsCanvasBackground()
        .navigationTitle(page.relativePath)
        .rnsInlineNavigationTitle()
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { statusBar }
        .task(id: page.id) { load() }
        .onChange(of: text) { _, _ in scheduleSave() }
        // `onDisappear` covers navigating back, but NOT backgrounding or
        // termination — iOS calls neither on the way to the app switcher. A
        // keystroke inside the debounce window would otherwise never reach disk.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flush() }
        }
        .onDisappear { flush() }
        .onChange(of: sizeClass) { _, new in
            // Split's tag disappears from the picker in a compact size class
            // (Slide Over, or an iPhone rotating to portrait). Leaving `mode`
            // on a tag the picker no longer offers renders it with no segment
            // selected at all, so move the stored value with it.
            if new == .compact, mode == .split { mode = .edit }
        }
        .sheet(isPresented: $showLinkBuilder) {
            MicronLinkBuilderSheet { snippet in insert(snippet) }
        }
        .sheet(isPresented: $showFieldBuilder) {
            MicronFieldBuilderSheet { snippet in insert(snippet) }
        }
        .alert("Could not save", isPresented: Binding(get: { saveError != nil },
                                                      set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Content

    /// The editor is ALWAYS mounted, and Preview mode collapses it to zero
    /// width rather than removing it.
    ///
    /// A `switch` over the mode put `editor` in a different `_ConditionalContent`
    /// branch per case, which is a different structural identity — so every
    /// Edit↔Split↔Preview switch deallocated the Runestone `TextView` and built
    /// a fresh one, dropping the caret, the scroll position, the keyboard and
    /// the whole undo stack. Keeping one instance in one position is what makes
    /// mode switching non-destructive.
    private var content: some View {
        HStack(spacing: 0) {
            editor
                .frame(maxWidth: effectiveMode == .preview ? 0 : .infinity)
                .opacity(effectiveMode == .preview ? 0 : 1)
                .accessibilityHidden(effectiveMode == .preview)
            if effectiveMode == .split {
                Divider()
            }
            if effectiveMode != .edit {
                preview
            }
        }
    }

    /// Split needs two panes' worth of width. On a phone it collapses to Edit
    /// rather than rendering two unusable columns.
    private var effectiveMode: EditorMode {
        (mode == .split && sizeClass == .compact) ? .edit : mode
    }

    private var editor: some View {
        VStack(spacing: 0) {
            // Read-only when the file could not be read, so an empty editor
            // cannot become an empty file.
            MicronSourceEditor(text: $text, tokens: tokens, isEditable: !loadFailed)
            if loadFailed {
                Label("This file could not be read as UTF-8 text and is shown empty. Editing is disabled so it is not overwritten.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.rnsWarning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                insertPalette
            }
        }
    }

    private var preview: some View {
        ScrollView {
            MicronView(nodes: MicronParser.parse(text)) { _, _ in
                // Links are inert in preview: following one would mean leaving
                // the editor mid-edit, and a relative link has no node to
                // resolve against until the page is actually being served.
            }
            .frame(maxWidth: previewWidth.points ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .rnsCanvasBackground()
    }

    // MARK: - Insert palette

    /// The backtick codes nobody memorises. Buttons wrap the selection where
    /// that makes sense; the two hardest constructs get their own builders.
    private var insertPalette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                paletteButton("Link", "link") { showLinkBuilder = true }
                paletteButton("Field", "character.cursor.ibeam") { showFieldBuilder = true }
                Divider().frame(height: 18)
                paletteButton("Bold", "bold") { insert("`!`!", caretBack: 2) }
                paletteButton("Italic", "italic") { insert("`*`*", caretBack: 2) }
                paletteButton("Underline", "underline") { insert("`_`_", caretBack: 2) }
                Divider().frame(height: 18)
                paletteButton("Heading", "textformat.size") { insertLinePrefix(">") }
                paletteButton("Divider", "minus") { insert("\n-\n") }
                paletteButton("Colour", "paintpalette") { insert("`F0af", caretBack: 0) }
                paletteButton("Reset", "arrow.counterclockwise") { insert("``") }
                Divider().frame(height: 18)
                paletteButton("Literal", "chevron.left.forwardslash.chevron.right") {
                    insert("\n`=\n\n`=\n", caretBack: 4)
                }
                paletteButton("Comment", "number") { insertLinePrefix("#") }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .rnsLegacyBarChrome()
        .rnsBarMaterial()
    }

    private func paletteButton(_ title: String, _ symbol: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(minWidth: 34, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(title)
        .help(title)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if diagnostics.isEmpty {
                Label("No issues", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(Color.rnsTextSecondary)
            } else {
                Button {
                    showDiagnostics.toggle()
                } label: {
                    Label("\(diagnostics.count) issue\(diagnostics.count == 1 ? "" : "s")",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.rnsWarning)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDiagnostics) {
                    diagnosticsList
                }
            }
            Spacer(minLength: 0)
            Text("\(text.count) chars · \(lineCount) lines")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.rnsTextMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .rnsLegacyBarChrome()
        .rnsBarMaterial(.screenBottom)
    }

    private var diagnosticsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, d in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: d.severity == .error
                              ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(d.severity == .error ? Color.rnsError : Color.rnsWarning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Line \(d.line)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.rnsTextSecondary)
                            Text(d.message)
                                .font(.caption)
                                .foregroundStyle(Color.rnsTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(minWidth: 280, maxWidth: 360, maxHeight: 320)
    }

    private var lineCount: Int {
        text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $mode) {
                ForEach(EditorMode.allCases, id: \.self) { m in
                    // Hide Split where it cannot work rather than offering a
                    // control that silently does something else.
                    if m != .split || sizeClass != .compact {
                        Text(m.label).tag(m)
                    }
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        if effectiveMode != .edit {
            ToolbarItem(placement: .rnsTrailing) {
                Picker("Preview width", selection: $previewWidth) {
                    ForEach(PreviewWidth.allCases, id: \.self) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.menu)
                .help("Preview at a fixed terminal width, the way NomadNet renders it")
            }
        }
    }

    // MARK: - Load / save

    private func load() {
        do {
            text = try store.read(page)
            savedText = text
            loadFailed = false
        } catch {
            // MUST leave `loadFailed` set. A page that could not be read shows
            // an empty editor, and autosave would then write that empty string
            // over a file that still has content — `store.read` throws
            // `.notUTF8` for any non-UTF-8 file, and the store lists every
            // regular file in the directory because `.mu` is a convention, not
            // a requirement. Pointing the root at a real node's storage/pages,
            // opening such a file and tapping Back destroyed it.
            text = ""
            savedText = nil
            loadFailed = true
            saveError = error.localizedDescription
        }
        loaded = true
    }

    /// Whether this page may be written at all. False until a successful read,
    /// so a failed load can never be saved over.
    private var canSave: Bool { loaded && !loadFailed }

    /// Debounced autosave. There is no dirty flag and no unsaved-changes dialog:
    /// this is a file the user is editing in place, and the whole feature is
    /// worth less if a page they typed is not the page on disk.
    ///
    /// The debounce is capped. Restarting the timer on every keystroke means a
    /// fast typist could go arbitrarily long with nothing on disk; after
    /// `maxDebounce` from the first unsaved edit, the next keystroke saves.
    private func scheduleSave() {
        guard canSave else { return }
        let now = Date()
        if firstUnsavedEdit == nil { firstUnsavedEdit = now }
        if let first = firstUnsavedEdit, now.timeIntervalSince(first) >= Self.maxDebounce {
            flush()
            return
        }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Cancel any pending debounce and write immediately.
    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    private func saveNow() {
        guard canSave else { return }
        // Skip a write that would change nothing. Without this, simply opening
        // a page wrote it back: `onChange(of: text)` sees the initial "" become
        // the file's contents and schedules a save, which rewrote the file and
        // bumped its modification date for a page the user only looked at.
        guard text != savedText else {
            firstUnsavedEdit = nil
            return
        }
        do {
            try store.write(text, to: page)
            savedText = text
            firstUnsavedEdit = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Insertion

    /// Appends at the end of the document. `MicronSourceEditor` does not expose
    /// the selection range yet — Runestone has one, but plumbing it back out
    /// through the representable is its own piece of work — so a selection-aware
    /// wrap is not possible here. `caretBack` is accepted now so callers already
    /// express intent for when that lands.
    private func insert(_ snippet: String, caretBack: Int = 0) {
        _ = caretBack
        text += snippet
    }

    private func insertLinePrefix(_ prefix: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += prefix
    }
}

// MARK: - Link builder

/// Wraps `MicronLinkSnippet`. All markup construction lives in that value type
/// so it can be unit-tested — as `@State private` fields in here it was
/// unreachable from a test, and it was wrong (see the `.page` case).
struct MicronLinkBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onInsert: (String) -> Void

    @State private var link = MicronLinkSnippet()

    var body: some View {
        NavigationStack {
            rnsSettingsContainer {
                Section {
                    Picker("Links to", selection: $link.kind) {
                        ForEach(MicronLinkSnippet.Kind.allCases, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    TextField("Target", text: $link.target, prompt: Text(link.kind.prompt))
                        .rnsNoAutocapitalization()
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    TextField("Label (optional)", text: $link.label)
                } footer: {
                    Text("With no label the URL itself is shown, which is what NomadNet does.")
                }

                Section("Preview") {
                    Text(link.snippet)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    if !link.offendingCharacters.isEmpty {
                        Label("Remove \(link.offendingCharacters.map(String.init).joined(separator: " and ")) — Micron ends the link at the first \"]\", and a backtick starts a new part of it.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.rnsWarning)
                    }
                }
            }
            .navigationTitle("Insert Link")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") { onInsert(link.snippet); dismiss() }
                        .disabled(!link.isUsable)
                }
            }
        }
    }
}

// MARK: - Field builder

/// Wraps `MicronFieldSnippet` — the one Micron construct nobody remembers.
struct MicronFieldBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onInsert: (String) -> Void

    @State private var field = MicronFieldSnippet()

    var body: some View {
        NavigationStack {
            rnsSettingsContainer {
                Section {
                    Picker("Type", selection: $field.kind) {
                        ForEach(MicronFieldSnippet.Kind.allCases, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    TextField("Field name", text: $field.name, prompt: Text("username"))
                        .rnsNoAutocapitalization()
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("The name is what the node receives the value under, as field_<name>.")
                }

                if field.kind.usesValue {
                    Section {
                        TextField("Submitted value", text: $field.value, prompt: Text("1"))
                            .font(.body.monospaced())
                        if field.kind == .checkbox {
                            Toggle("Checked by default", isOn: $field.prechecked)
                        }
                    } footer: {
                        Text(field.kind == .radio
                             ? "Radio buttons sharing a name form one group; the value distinguishes them."
                             : "The value sent when the box is ticked.")
                    }
                } else {
                    Section {
                        Toggle("Set width", isOn: $field.useWidth)
                        if field.useWidth {
                            Stepper("Width: \(field.width)", value: $field.width, in: 1...256)
                        }
                        TextField("Pre-filled text", text: $field.data)
                    } footer: {
                        Text("Width is capped at 256 and defaults to 24.")
                    }
                }

                Section("Preview") {
                    Text(field.snippet.isEmpty ? "—" : field.snippet)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    if !field.offendingCharacters.isEmpty {
                        Label("Remove \(field.offendingCharacters.map(String.init).joined(separator: " and ")) — Micron ends the field at the first \">\", and \"`\" and \"|\" separate its parts.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.rnsWarning)
                    }
                    if field.kind.usesValue {
                        Text("Write the visible label as plain text after the field — NomadNet's own examples leave the in-field label empty.")
                            .font(.caption)
                            .foregroundStyle(Color.rnsTextSecondary)
                    }
                }
            }
            .navigationTitle("Insert Field")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") { onInsert(field.snippet); dismiss() }
                        .disabled(!field.isUsable)
                }
            }
        }
    }
}

#endif
