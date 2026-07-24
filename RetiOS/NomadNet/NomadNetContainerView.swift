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
                case .pages:
                    PagesContent()
                }
            }
            .rnsSectionPicker([
                ("Browse",    NomadSection.browse),
                ("Peers",     NomadSection.peers),
                ("Favorites", NomadSection.favorites),
                ("Channels",  NomadSection.channels),
                ("Pages",     NomadSection.pages)
            ], selection: $section)
            // Flush pinned title (no large-title dead space) — matches the
            // Messages tab. Replaces `.navigationTitle` + `.rnsNavigationBar()`.
            .rnsPinnedTitle("NomadNet")
        }
    }
}

enum NomadSection: String, Hashable, CaseIterable {
    case browse, peers, favorites, channels, pages

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
    let onBrowse: (String) -> Void

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
        List(nodes) { node in
            NomadNodeRow(node: node, onBrowse: onBrowse) {
                node.isFavorite.toggle()
                try? context.save()
            }
            .rnsRow()
        }
        .rnsContentListStyle()
        .rnsScreenBackground()
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
    let onBrowse: (String) -> Void

    var body: some View {
        Group {
            if favorites.isEmpty {
                RNSEmptyState(
                    title: "No Favorites",
                    systemImage: "star",
                    description: "Tap the star next to a node in the Peers list to pin it here for quick access."
                )
            } else {
                List(favorites) { node in
                    NomadNodeRow(node: node, onBrowse: onBrowse) {
                        node.isFavorite.toggle()
                        try? context.save()
                    }
                    .rnsRow()
                }
                .rnsContentListStyle()
                .rnsScreenBackground()
            }
        }
    }
}
