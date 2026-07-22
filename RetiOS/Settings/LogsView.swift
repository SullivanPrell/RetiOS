import SwiftUI
import ReticulumSwift

struct LogsView: View {
    @EnvironmentObject var logStore: RNSLogStore
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var showClearConfirm = false

    private var filtered: [RNSLogEntry] {
        guard !searchText.isEmpty else { return logStore.entries }
        return logStore.entries.filter {
            $0.message.localizedCaseInsensitiveContains(searchText)
                || $0.level.abbreviation.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var exportText: String {
        // Export what's visible — respects an active search filter rather than
        // silently sharing the full, unfiltered log.
        filtered.map(\.formatted).joined(separator: "\n")
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(filtered) { entry in
                LogEntryRow(entry: entry)
                    .id(entry.id)
                    .rnsRow()
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            .listStyle(.plain)
            .rnsScreenBackground()
            // Key on the last visible row's identity, not the count: once the
            // ring buffer is full the count is pinned at its cap (new entries
            // evict old ones), so `count` stops changing and count-keyed
            // auto-scroll silently freezes. The last id still changes per entry.
            .onChange(of: filtered.last?.id) { _, _ in
                guard autoScroll, let last = filtered.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        .searchable(text: $searchText, prompt: "Search logs")
        .navigationTitle("RNS Logs")
        .rnsInlineNavigationTitle()
        .rnsNavigationBar()
        .toolbar {
            ToolbarItemGroup(placement: .rnsTrailing) {
                Button {
                    autoScroll.toggle()
                } label: {
                    // NOTE: `arrow.down.to.line.slash` is not a real SF Symbol
                    // name — passing it to `Image(systemName:)` makes the
                    // system log "No symbol named '...' found in system
                    // symbol set" *every time the view re-renders*, which
                    // (combined with the toolbar's other state changes)
                    // produced an endless loop of that message in the
                    // console and visually broke the toolbar. Use a single,
                    // real symbol for both states and convey on/off purely
                    // via tint + opacity instead of swapping glyph names.
                    Image(systemName: "arrow.down.to.line")
                        .opacity(autoScroll ? 1.0 : 0.4)
                }
                .tint(autoScroll ? .rnsAccent : .secondary)
                .help(autoScroll ? "Auto-scroll on" : "Auto-scroll off")
                .accessibilityLabel(autoScroll ? "Auto-scroll on" : "Auto-scroll off")

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Clear logs")

                ShareLink(
                    item: exportText,
                    subject: Text("RNS Logs"),
                    message: Text("Exported from RetiOS")
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export logs")
            }
        }
        .confirmationDialog(
            "Clear All Logs",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Logs", role: .destructive) { logStore.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently clears the captured RNS log for this session.")
        }
        .overlay {
            if filtered.isEmpty {
                if logStore.entries.isEmpty {
                    RNSEmptyState(
                        title: "No Logs Yet",
                        systemImage: "terminal",
                        description: "Log messages from the Reticulum stack appear here."
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                        .rnsCanvasBackground()
                }
            }
        }
    }
}

// MARK: - Log entry row

private struct LogEntryRow: View {
    let entry: RNSLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RNSBadge(text: entry.level.abbreviation,
                     color: entry.level.levelColor,
                     monospaced: true)
                .accessibilityLabel(entry.level.displayName)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.timestampString)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(entry.message)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(entry.level.levelColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
    }
}
