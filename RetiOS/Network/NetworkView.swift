import SwiftUI
import ReticulumSwift

// MARK: - ToolsView
//
// Top-level "RNS Tools" menu item — four sub-pages via a segmented control:
//   Paths       — the live transport path table
//   Announces   — raw announce log from the transport
//   Ping        — path ping / node info
//   Visualizer  — live network graph (nodes, edges, connection types)

struct ToolsView: View {
    @EnvironmentObject var stack: StackController
    @State private var selection: Tab = .paths

    enum Tab: String, CaseIterable {
        case paths      = "Paths"
        case announces  = "Announces"
        case ping       = "Ping"
        case visualizer = "Visualizer"
    }

    var body: some View {
        VStack(spacing: 0) {
            RNSSectionPicker(
                Tab.allCases.map { ($0.rawValue, $0) },
                selection: $selection
            )

            Group {
                switch selection {
                case .paths:      PathTableView()
                case .announces:  AnnouncesView()
                case .ping:       NetworkToolsView()
                case .visualizer: NetworkVisualizerView()
                }
            }
            .environmentObject(stack)
        }
        .rnsCanvasBackground()
        .navigationTitle("Tools")
    }
}

// MARK: - Path table

private struct PathTableView: View {
    @EnvironmentObject var stack: StackController
    @State private var paths: [(hash: String, hops: UInt8, interface: String)] = []
    private let refreshInterval: TimeInterval = 3

    var body: some View {
        Group {
            if paths.isEmpty {
                emptyState
            } else {
                List(paths, id: \.hash) { path in
                    PathRow(hash: path.hash, hops: path.hops, interfaceName: path.interface)
                        .rnsRow()
                }
                .listStyle(.plain)
                .rnsScreenBackground()
                // safeAreaInset (not overlay) so the last row isn't hidden
                // behind the translucent count bar.
                .safeAreaInset(edge: .bottom) {
                    Text("\(paths.count) path\(paths.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
        }
        .onAppear { refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                refresh()
            }
        }
    }

    private func refresh() {
        guard let transport = stack.transport else { return }
        paths = transport.getPathTable().map { entry in
            let hashHex = entry.destinationHash.map { String(format: "%02x", $0) }.joined()
            return (hash: hashHex, hops: entry.hops, interface: entry.interfaceName)
        }
        .sorted { $0.hops < $1.hops }
    }

    private var emptyState: some View {
        RNSEmptyState(
            title: "No paths yet",
            systemImage: "map",
            description: "Reticulum path entries appear here as announces and traffic arrive across the mesh."
        )
    }
}

private struct PathRow: View {
    let hash: String
    let hops: UInt8
    let interfaceName: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hash.truncatedHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                Text(interfaceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "arrow.forward.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.rnsAccent)
                    .accessibilityHidden(true)
                Text("\(hops) hop\(hops == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Announces log

private struct AnnouncesView: View {
    @EnvironmentObject var stack: StackController
    @State private var knownIdentities: [String] = []
    private let refreshInterval: TimeInterval = 5

    var body: some View {
        Group {
            if knownIdentities.isEmpty {
                RNSEmptyState(
                    title: "No announces yet",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: "Node announces appear here as they arrive across the mesh."
                )
            } else {
                List {
                    ForEach(knownIdentities, id: \.self) { entry in
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(Color.rnsAccent)
                                .frame(width: 24)
                            Text(entry.truncatedHash)
                                .font(.caption.monospaced())
                            Spacer()
                        }
                        .padding(.vertical, 1)
                        .rnsRow()
                    }
                }
                .listStyle(.plain)
                .rnsScreenBackground()
                // safeAreaInset (not overlay) so the last row isn't hidden
                // behind the translucent count bar.
                .safeAreaInset(edge: .bottom) {
                    countBar
                }
            }
        }
        .onAppear { refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                refresh()
            }
        }
    }

    private func refresh() {
        guard let transport = stack.transport else { return }
        knownIdentities = transport.knownIdentities.keys
            .map { key in key.map { String(format: "%02x", $0) }.joined() }
            .sorted()
    }

    private var countBar: some View {
        Text("\(knownIdentities.count) known identit\(knownIdentities.count == 1 ? "y" : "ies")")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
    }
}

// MARK: - Network tools

private struct NetworkToolsView: View {
    @EnvironmentObject var stack: StackController
    @State private var pingTarget = ""
    @State private var pingResult: String?
    @State private var isPinging = false
    @State private var nodeInfo: NodeInfo?

    private struct NodeInfo {
        let paths: Int
        let identities: Int
        let interfaces: Int
    }

    private let infoRefreshInterval: TimeInterval = 3

    var body: some View {
        Form {
            pingSection
            infoSection
        }
        .rnsScreenBackground()
        // Node Info counts were read once at render and never updated. Poll on
        // the same cadence as the Paths/Announces tabs so the figures stay live.
        .task {
            refreshNodeInfo()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(infoRefreshInterval))
                refreshNodeInfo()
            }
        }
    }

    private func refreshNodeInfo() {
        guard let transport = stack.transport else {
            nodeInfo = nil
            return
        }
        nodeInfo = NodeInfo(
            paths: transport.getPathTable().count,
            identities: transport.knownIdentities.count,
            interfaces: transport.interfaces.count
        )
    }

    private var pingSection: some View {
        Section {
            TextField("Destination hash (32 hex chars)", text: $pingTarget)
                .autocorrectionDisabled()
                .rnsNoAutocapitalization()
                .font(.caption.monospaced())
                .onChange(of: pingTarget) { _, new in
                    pingTarget = String(new.filter { $0.isHexDigit }.prefix(32))
                    pingResult = nil
                }

            Button {
                Task { await ping() }
            } label: {
                HStack {
                    if isPinging { ProgressView().controlSize(.small) }
                    Text(isPinging ? "Pinging…" : "Ping")
                }
            }
            .disabled(pingTarget.filter { $0.isHexDigit }.count != 32 || !stack.isRunning || isPinging)

            if let result = pingResult {
                Text(result)
                    .font(.caption.monospaced())
                    .foregroundStyle(result.hasPrefix("✓") ? Color.rnsSuccess : Color.rnsError)
            }
        } header: {
            Text("Path Ping")
        } footer: {
            Text("Sends an RNS path request and reports whether a route exists.")
        }
        .rnsRow()
    }

    private var infoSection: some View {
        Section("Node Info") {
            if let info = nodeInfo {
                LabeledContent("Paths known") {
                    Text("\(info.paths)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Identities known") {
                    Text("\(info.identities)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Interfaces") {
                    Text("\(info.interfaces)")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Stack not running")
                    .foregroundStyle(.secondary)
            }
        }
        .rnsRow()
    }

    @MainActor
    private func ping() async {
        let hex = String(pingTarget.filter { $0.isHexDigit }.prefix(32))
        guard let hashData = Data(hexString: hex),
              let transport = stack.transport else {
            pingResult = "✗ Invalid hash"
            return
        }
        isPinging = true
        defer { isPinging = false }

        if transport.hasPath(to: hashData) {
            let hops = transport.getPathTable()
                .first { $0.destinationHash == hashData }
                .map { "\($0.hops) hop\($0.hops == 1 ? "" : "s")" } ?? "path known"
            pingResult = "✓ Path exists (\(hops))"
        } else {
            try? transport.requestPath(for: hashData)
            try? await Task.sleep(for: .seconds(3))
            if transport.hasPath(to: hashData) {
                pingResult = "✓ Path found after request"
            } else {
                pingResult = "✗ No path found (destination may be offline)"
            }
        }
    }
}

// MARK: - Hex string helper

private extension Data {
    init?<S: StringProtocol>(hexString: S) {
        let hex = String(hexString.filter { $0.isHexDigit })
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let nextIdx = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<nextIdx], radix: 16) else { return nil }
            data.append(byte)
            idx = nextIdx
        }
        self = data
    }
}
