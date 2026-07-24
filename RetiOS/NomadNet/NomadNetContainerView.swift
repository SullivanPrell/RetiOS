import SwiftUI
import SwiftData

// Phone tab combining NomadNet browser, node peer list, and RRC channels.
// iPad sidebar uses NomadNetBrowserView and ChannelsView as separate detail panes.
//
// The segmented picker lives in the content area (not the toolbar) so that:
//  • Section switches don't touch the navigation bar at all, preventing
//    iOS 26 Liquid Glass animation artifacts.
//  • The navigation bar is minimal — no extra height from a toolbar principal item.
struct NomadNetContainerView: View {
    @Environment(NomadNetController.self) private var nomadNet
    @State private var section: NomadSection = .launchSelection

    var body: some View {
        NavigationStack {
            // Content — each case fills all remaining space.
            Group {
                switch section {
                case .browse:
                    NomadNetBrowserContent()
                case .peers:
                    NomadNetPeersContent { hash in
                        nomadNet.navigate(to: hash)
                        section = .browse
                    }
                case .favorites:
                    NomadNetFavoritesContent { hash in
                        nomadNet.navigate(to: hash)
                        section = .browse
                    }
                case .channels:
                    ChannelsContent()
                #if os(iOS)
                case .pages:
                    PagesContent()
                #endif
                }
            }
            .rnsSectionPicker(Self.sections, selection: $section)
            // Flush pinned title (no large-title dead space) — matches the
            // Messages tab. Replaces `.navigationTitle` + `.rnsNavigationBar()`.
            .rnsPinnedTitle("NomadNet")
        }
    }

    /// Segments offered by the picker, in order.
    ///
    /// Built from `NomadSection.allCases` rather than spelled out a second time,
    /// so the picker cannot drift from the switch above — on macOS `.pages` does
    /// not exist as a case at all, and a hand-written array would still offer a
    /// segment that resolves to nothing.
    private static let sections: [(String, NomadSection)] =
        NomadSection.allCases.map { ($0.title, $0) }
}

/// The NomadNet tab's segments.
///
/// `.pages` is **iOS/iPadOS only**. The Micron page editor is built on
/// Runestone, a UIKit-only code editor (see MicronSourceEditor.swift); the Mac
/// had no equivalent surface, so rather than ship a degraded one the section is
/// compiled out of the Mac slice entirely. Omitting the *case* — not just the
/// picker entry — is what makes it unreachable by construction: `allCases` has
/// no `.pages` on macOS, so the DEBUG `-startSection pages` launch argument
/// matches nothing there and falls through to `.browse` rather than selecting a
/// segment with no content behind it.
enum NomadSection: String, Hashable, CaseIterable {
    case browse, peers, favorites, channels
    #if os(iOS)
    case pages
    #endif

    /// Picker label. Derived here rather than at the call site so a new case
    /// cannot be added without naming it.
    var title: String {
        switch self {
        case .browse:    return "Browse"
        case .peers:     return "Peers"
        case .favorites: return "Favorites"
        case .channels:  return "Channels"
        #if os(iOS)
        case .pages:     return "Pages"
        #endif
        }
    }

    /// Which segment this tab starts on. Normally Browse; a DEBUG build also
    /// honours `-startSection <raw>`, the same convention `NetworkView.Tab` uses
    /// so `scripts/mac-screens.sh` can photograph a segment other than the
    /// default. Never compiled into Release.
    static var launchSelection: NomadSection {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "startSection"),
           let section = NomadSection.allCases.first(where: {
               $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame
           }) {
            return section
        }
        #endif
        return .browse
    }
}

// MARK: - NomadNet Peers content

struct NomadNetPeersContent: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \NomadNodeEntity.lastSeen, order: .reverse) private var nodes: [NomadNodeEntity]
    @State private var searchText = ""
    let onBrowse: (String) -> Void

    /// Same filter as Destinations ▸ Peers: display name OR destination hash,
    /// case-insensitively. Announce-derived nodes often have no name at all, so
    /// matching the hash is the only way to find one of those.
    private var filtered: [NomadNodeEntity] {
        guard let q = RNSSearch.query(searchText) else { return nodes }
        return nodes.filter { RNSSearch.matches(q, name: $0.displayName, hash: $0.destinationHash) }
    }

    var body: some View {
        Group {
            if nodes.isEmpty {
                emptyState
            } else {
                nodeList
            }
        }
    }

    private var nodeList: some View {
        List(filtered) { node in
            NomadNodeRow(node: node, onBrowse: onBrowse) {
                node.isFavorite.toggle()
                try? context.save()
            }
            .rnsRow()
        }
        .rnsContentListStyle()
        .rnsScreenBackground()
        // Standard no-results state instead of a blank list when the query
        // matches no node. Applied to the List *before* the field is stacked
        // above it — after, it would cover the field and a no-results query
        // could never be cleared.
        .overlay {
            if filtered.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        // NOT `.searchable`: this is a tab root under `rnsPinnedTitle`, which
        // hides the navigation bar that every iOS SearchFieldPlacement resolves
        // into — the field renders nothing at all, silently. See
        // `rnsInlineSearch`.
        .rnsInlineSearch(text: $searchText)
    }

    private var emptyState: some View {
        RNSEmptyState(
            title: "No NomadNet Nodes",
            systemImage: "globe.americas",
            description: "NomadNet nodes appear here as their announces arrive across the mesh. Tap Browse to load a node's pages."
        )
    }
}

// MARK: - Node row (shared by Peers and Favorites)

private struct NomadNodeRow: View {
    let node: NomadNodeEntity
    let onBrowse: (String) -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleFavorite) {
                Image(systemName: node.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(node.isFavorite ? Color.rnsWarning : Color.rnsTextMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(node.isFavorite ? "Remove from favorites" : "Add to favorites")

            // Shared identity block — same as the LXMF/LXST peer rows.
            PeerIdentityView(name: node.displayName ?? "Unknown Node",
                             hash: node.destinationHash,
                             lastSeen: node.lastSeen)
            Spacer()
            Button("Browse") { onBrowse(node.destinationHash) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.rnsAccent)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - NomadNet Favorites content

/// Nodes the user has starred for quick access — a curated subset of the
/// full announce-derived Peers list (mirrors the Messages/Contacts pattern).
struct NomadNetFavoritesContent: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<NomadNodeEntity> { $0.isFavorite == true },
           sort: \NomadNodeEntity.lastSeen, order: .reverse) private var favorites: [NomadNodeEntity]
    @State private var searchText = ""
    let onBrowse: (String) -> Void

    /// Same filter as the Peers list — name or hash, case-insensitively.
    private var filtered: [NomadNodeEntity] {
        guard let q = RNSSearch.query(searchText) else { return favorites }
        return favorites.filter { RNSSearch.matches(q, name: $0.displayName, hash: $0.destinationHash) }
    }

    var body: some View {
        Group {
            if favorites.isEmpty {
                RNSEmptyState(
                    title: "No Favorites",
                    systemImage: "star",
                    description: "Tap the star next to a node in the Peers list to pin it here for quick access."
                )
            } else {
                List(filtered) { node in
                    NomadNodeRow(node: node, onBrowse: onBrowse) {
                        node.isFavorite.toggle()
                        try? context.save()
                    }
                    .rnsRow()
                }
                .rnsContentListStyle()
                .rnsScreenBackground()
                .overlay {
                    if filtered.isEmpty && !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                .rnsInlineSearch(text: $searchText)
            }
        }
    }
}
