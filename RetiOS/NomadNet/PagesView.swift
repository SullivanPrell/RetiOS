#if os(iOS)

import SwiftUI
import UniformTypeIdentifiers

// The page library: the "Pages" section of the NomadNet tab.
//
// iOS/iPadOS only. The whole point of the library is the Micron editor it opens
// into, and that editor is Runestone — UIKit-only, linked with XcodeGen
// `destinationFilters: [iOS]` (see MicronSourceEditor.swift). Shipping the list
// on the Mac would mean shipping a second-class editor behind it, so the section
// is compiled out of the Mac slice entirely; `NomadSection` has no `.pages` case
// there.
//
// PagesContent is the inner content — no NavigationStack — so it slots into
// NomadNetContainerView's section switcher alongside Browse / Peers / Favorites
// / Channels, exactly like ChannelsContent.
//
// These are real `.mu` files in Python NomadNet's own directory layout (see
// MicronPageStore), not database rows. That is what makes the relocatable root
// work: the Files-app folder picker can point this at a shared NomadNet
// `storage/pages` and edit pages that are already being served to peers.
struct PagesContent: View {
    @Environment(MicronPageStore.self) private var store

    @State private var showNewPageAlert = false
    @State private var newPageName = ""
    @State private var renameTarget: MicronPage?
    @State private var renameText = ""
    @State private var deleteTarget: MicronPage?
    @State private var showImporter = false
    @State private var showRootPicker = false
    @State private var selection: MicronPage?

    var body: some View {
        Group {
            if store.pages.isEmpty {
                emptyState
            } else {
                pageList
            }
        }
        .rnsCanvasBackground()
        .safeAreaInset(edge: .bottom) { rootFooter }
        .toolbar {
            ToolbarItem(placement: .rnsTrailing) {
                Menu {
                    Button {
                        newPageName = ""
                        showNewPageAlert = true
                    } label: {
                        Label("New Page", systemImage: "doc.badge.plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button {
                        showRootPicker = true
                    } label: {
                        Label("Choose Pages Folder…", systemImage: "folder")
                    }
                    if store.isUsingCustomRoot {
                        Button {
                            store.resetRootToDefault()
                        } label: {
                            Label("Use Default Folder", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Page actions")
            }
        }
        .alert("New Page", isPresented: $showNewPageAlert) {
            TextField("index.mu", text: $newPageName)
                .rnsNoAutocapitalization()
                .autocorrectionDisabled()
            Button("Create") { createPage() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Micron pages use the .mu extension. \"index.mu\" is the page a peer gets when they browse your node without naming one.")
        }
        .alert("Rename Page", isPresented: Binding(get: { renameTarget != nil },
                                                   set: { if !$0 { renameTarget = nil } })) {
            TextField("name.mu", text: $renameText)
                .rnsNoAutocapitalization()
                .autocorrectionDisabled()
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete \"\(deleteTarget?.relativePath ?? "page")\"?",
            isPresented: Binding(get: { deleteTarget != nil },
                                 set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let page = deleteTarget { try? store.delete(page) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("The file is removed from disk. This cannot be undone.")
        }
        // Scoped importers rather than UIFileSharingEnabled: exposing the whole
        // Documents container to Files.app would also expose the Reticulum
        // identity private key, which lives at Documents/reticulum/.
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.plainText, .text, .data],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .fileImporter(isPresented: $showRootPicker,
                      allowedContentTypes: [.folder]) { result in
            handleRootPick(result)
        }
        .alert("Pages",
               isPresented: Binding(get: { store.lastError != nil },
                                    set: { if !$0 { store.clearError() } })) {
            Button("OK") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
        .onAppear { store.reload() }
    }

    // MARK: - List

    private var pageList: some View {
        List {
            ForEach(store.pages) { page in
                NavigationLink {
                    MicronPageEditorView(page: page)
                        .environment(store)
                } label: {
                    PageRow(page: page)
                }
                .rnsRow()
                .contextMenu {
                    Button {
                        renameTarget = page
                        renameText = page.url.lastPathComponent
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        try? store.duplicate(page)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    ShareLink(item: page.url) {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleteTarget = page
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteTarget = page
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        renameTarget = page
                        renameText = page.url.lastPathComponent
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.rnsAccent)
                }
            }
        }
        .rnsContentListStyle()
        .rnsScreenBackground()
    }

    private var emptyState: some View {
        RNSEmptyState(
            title: "No Pages",
            systemImage: "doc.richtext",
            description: "Micron pages are the documents a NomadNet node serves. Create one to start writing, or import a .mu file from another node.",
            actionTitle: "New Page"
        ) {
            newPageName = "index.mu"
            showNewPageAlert = true
        }
    }

    /// Where the pages actually live. Worth permanent screen space rather than
    /// burying it in a menu: with a custom root these files may be a live node's
    /// served pages, and editing those has consequences the author should not
    /// have to remember.
    private var rootFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: store.isUsingCustomRoot ? "folder.badge.gearshape" : "folder")
                .foregroundStyle(Color.rnsTextMuted)
            Text(store.rootDisplayPath)
                .font(.caption2.monospaced())
                .foregroundStyle(Color.rnsTextSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if store.isUsingCustomRoot {
                RNSBadge(text: "custom", neutral: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .rnsLegacyBarChrome()
        .rnsBarMaterial()
        .help(store.rootURL.path(percentEncoded: false))
    }

    // MARK: - Actions

    private func createPage() {
        let name = newPageName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? store.create(named: name, contents: MicronPageStore.starterTemplate)
    }

    private func performRename() {
        guard let page = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renameTarget = nil
        // Compare against the FILENAME, not the relative path. `store.rename`
        // takes a single path component — `validatedName` rejects anything
        // containing "/" — so a nested page prefilled with "sub/about.mu" could
        // never be renamed at all: every attempt threw .invalidName. The page
        // stays in its directory; only the last component changes.
        guard !name.isEmpty, name != page.url.lastPathComponent else { return }
        try? store.rename(page, to: name)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            // A picked file is outside the app container, so it needs its scope
            // opened for the duration of the copy — without this the read fails
            // with a permission error on both platforms.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try? store.importPage(from: url)
        }
    }

    private func handleRootPick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        try? store.setRoot(url)
    }
}

// MARK: - Row

private struct PageRow: View {
    let page: MicronPage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: page.isIndex ? "house" : "doc.text")
                .foregroundStyle(page.isIndex ? Color.rnsAccent : Color.rnsTextMuted)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(page.relativePath)
                    .font(.body.monospaced())
                    .foregroundStyle(Color.rnsTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(page.byteCount.formatted(.byteCount(style: .file))) · \(RNSDate.listTimestamp(page.modified))")
                    .font(.caption2)
                    .foregroundStyle(Color.rnsTextSecondary)
            }
            Spacer(minLength: 0)
            if page.isIndex {
                RNSBadge(text: "index")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#endif
