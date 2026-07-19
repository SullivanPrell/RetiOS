import SwiftUI

// MARK: - InterfaceDirectorySheet
//
// Browses the public interface directory at https://directory.rns.recipes
// and lets the user quick-add a community-run gateway as a saved
// TCPClientInterface / BackboneInterface with one tap.

struct InterfaceDirectorySheet: View {
    @EnvironmentObject var stack: StackController
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [InterfaceDirectory.Entry] = []
    @State private var loadError: String?
    @State private var addError: String?
    @State private var search = ""
    @State private var addedNames: Set<String> = []

    private var quickAddable: [InterfaceDirectory.Entry] {
        entries.filter(\.isQuickAddable)
    }

    private var filtered: [InterfaceDirectory.Entry] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return quickAddable }
        let needle = trimmed.lowercased()
        return quickAddable.filter {
            $0.name.lowercased().contains(needle) || $0.host.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            // List is always the root view so `.searchable()` and `.rnsScreenBackground()`
            // are always on the same stable view type. Switching the root between
            // ProgressView / ContentUnavailableView / List caused UISearchController to
            // detach and reattach on every state change — producing a one-frame zero-size
            // Metal layer and the layoutSubtreeIfNeeded recursion warning. The overlay
            // handles all loading/error/empty visuals without changing the root type.
            List {
                if let err = addError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.rnsError)
                    }
                    .rnsRow()
                }
                if !filtered.isEmpty {
                    Section {
                        ForEach(filtered) { entry in
                            DirectoryEntryRow(entry: entry,
                                              isAdded: hasBeenAdded(entry)) {
                                add(entry)
                            }
                            .rnsRow()
                        }
                    } footer: {
                        Text("Entries are reported online by community members. Connecting routes your traffic through their node — only add gateways you trust.")
                    }
                }
            }
            .refreshable { await load(force: true) }
            .overlay {
                if entries.isEmpty && loadError == nil {
                    // Unlabeled spinner: the HIG advises against vague labels like
                    // "Loading…" (and against labeling a spinner at all on macOS).
                    // The "Public Directory" nav title already supplies context.
                    ProgressView()
                } else if let err = loadError, entries.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load Directory", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(err)
                    } actions: {
                        Button("Retry") { Task { await load(force: true) } }
                            .buttonStyle(.bordered)
                    }
                } else if filtered.isEmpty {
                    if search.isEmpty {
                        RNSEmptyState(title: "No Interfaces Online", systemImage: "network.slash",
                                      description: "The public directory has no quick-addable gateways online right now.")
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            .rnsScreenBackground()
            .navigationTitle("Public Directory")
            .rnsInlineNavigationTitle()
            .searchable(text: $search, prompt: "Search by name or host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
        #if os(macOS)
        // macOS sheets size to their content; without an explicit frame a
        // NavigationStack-wrapped List collapses to near-zero height — this is
        // the "pop-up opens collapsed with no options" bug. Give it a real size.
        .frame(minWidth: 460, idealWidth: 560, minHeight: 520, idealHeight: 680)
        #endif
    }

    private func hasBeenAdded(_ entry: InterfaceDirectory.Entry) -> Bool {
        addedNames.contains(entry.name) || stack.savedInterfaces.contains { $0.name == entry.name }
    }

    // `isLoading` was removed: the overlay already uses `entries.isEmpty && loadError == nil`
    // as the loading sentinel. Keeping a separate Bool caused 4 @State mutations per load
    // cycle, which destabilised UISearchController (ViewBridge termination warnings).
    private func load(force: Bool = false) async {
        guard force || entries.isEmpty else { return }
        if force { loadError = nil }
        do {
            let result = try await InterfaceDirectory.fetchOnline()
            entries = result
        } catch is CancellationError {
            // Task was cancelled (sheet dismissed) — benign.
        } catch {
            loadError = "Check your connection and try again."
        }
    }

    private func add(_ entry: InterfaceDirectory.Entry) {
        guard let kind = entry.savedKind, let port = entry.port, let portNum = UInt16(exactly: port) else { return }
        addError = nil
        do {
            try stack.addAndSaveInterface(name: entry.name, host: entry.host, port: portNum, kind: kind)
            addedNames.insert(entry.name)
        } catch {
            addError = error.localizedDescription
        }
    }
}

// MARK: - Directory entry row

private struct DirectoryEntryRow: View {
    let entry: InterfaceDirectory.Entry
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .frame(width: 28)
                .foregroundStyle(Color.rnsAccent)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.hostPort)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    badge(entry.network.uppercased())
                    badge(entry.typeLabel)
                }
            }

            Spacer(minLength: 8)

            if isAdded {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.rnsSuccess)
                    .font(.title3)
            } else {
                Button("Add", action: onAdd)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.rnsAccent)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        entry.type == "backbone" ? "point.3.connected.trianglepath.dotted" : "network"
    }

    private func badge(_ text: String) -> some View {
        // Neutral metadata pill — opaque surface fill + secondary text. (Passing
        // a translucent label color as the tint would render the pill at ~5%
        // alpha and drop the text below the contrast floor.)
        RNSBadge(text: text, neutral: true)
    }
}
