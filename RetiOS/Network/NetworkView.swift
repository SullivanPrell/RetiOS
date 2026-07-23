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
    @Environment(StackController.self) private var stack
    @State private var selection: Tab = .launchSelection

    enum Tab: String, CaseIterable {
        case paths      = "Paths"
        case announces  = "Announces"
        case ping       = "Ping"
        case visualizer = "Visualizer"

        /// Which segment this screen starts on.
        ///
        /// Normally Paths. A DEBUG build additionally honours
        /// `-startSection <raw>`, mirroring `AppTab.launchSelection`'s
        /// `-startTab`. Without it `scripts/mac-screens.sh` could only ever
        /// photograph the Paths segment — the Ping and Visualizer panes, both of
        /// which had reported visual defects, were unreachable by any harness in
        /// the repo, so there was no way to check a fix without a manual build
        /// and click-through. Case-insensitive because the raw values are
        /// display strings ("Ping") while every other launch argument in the app
        /// is lowercase. Never compiled into Release.
        static var launchSelection: Tab {
            #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: "startSection"),
               let tab = Tab.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }) {
                return tab
            }
            #endif
            return .paths
        }
    }

    var body: some View {
        Group {
            switch selection {
            case .paths:      PathTableView()
            case .announces:  AnnouncesView()
            case .ping:       NetworkToolsView()
            case .visualizer: NetworkVisualizerView()
            }
        }
        .environment(stack)
        .rnsSectionPicker(
            Tab.allCases.map { ($0.rawValue, $0) },
            selection: $selection
        )
        .rnsCanvasBackground()
        .navigationTitle("Tools")
    }
}

// MARK: - Path table

private struct PathTableView: View {
    @Environment(StackController.self) private var stack
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
                .rnsContentListStyle()
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
        // The hash is shown truncated; let people copy the full value (e.g. to
        // paste into the Ping field). Copying the full hash, not the ellipsis form.
        .contextMenu {
            Button {
                rnsCopyToPasteboard(hash)
            } label: {
                Label("Copy Hash", systemImage: "doc.on.doc")
            }
        }
    }
}

// MARK: - Announces log

private struct AnnouncesView: View {
    @Environment(StackController.self) private var stack
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
                        .contextMenu {
                            Button {
                                rnsCopyToPasteboard(entry)
                            } label: {
                                Label("Copy Hash", systemImage: "doc.on.doc")
                            }
                        }
                        .rnsRow()
                    }
                }
                .rnsContentListStyle()
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
    @Environment(StackController.self) private var stack
    @State private var pingTarget = ""
    @State private var pingResult: PingOutcome?
    @State private var isPinging = false
    @State private var nodeInfo: NodeInfo?

    /// `Equatable` so `refreshNodeInfo` can assign only on change. Writing
    /// `@State` unconditionally re-rendered the whole pane every 3 s even when
    /// the counts were identical — the same defect
    /// `SettingsView.refreshCachedStats` already carries a comment about. It
    /// matters more here than there: a 3-second full-pane invalidation next to a
    /// focused macOS text field is a focus and selection hazard.
    private struct NodeInfo: Equatable {
        let paths: Int
        let identities: Int
        let interfaces: Int
    }

    /// The outcome of a ping, as data rather than a "✓"-prefixed string.
    ///
    /// The result row used to pick its colour with `result.hasPrefix("✓")`,
    /// which put the success/failure signal inside the presentation string — any
    /// wording change silently flipped the colour.
    private enum PingOutcome {
        case reachable(String)
        case unreachable(String)

        var message: String {
            switch self {
            case .reachable(let text), .unreachable(let text): return text
            }
        }
        var symbol: String {
            switch self {
            case .reachable:   return "checkmark.circle.fill"
            case .unreachable: return "xmark.octagon.fill"
            }
        }
        var tint: Color {
            switch self {
            case .reachable:   return .rnsSuccess
            case .unreachable: return .rnsError
            }
        }
        /// The result lands up to 3 s after the tap, so VoiceOver names the state
        /// explicitly rather than reading the message alone.
        var accessibilityPrefix: String {
            switch self {
            case .reachable:   return "Reachable"
            case .unreachable: return "Unreachable"
            }
        }
    }

    private let infoRefreshInterval: TimeInterval = 3

    var body: some View {
        // `rnsSettingsContainer`, not a bare `Form`. An unstyled Form on macOS
        // resolves to the *columns* layout — "a non-scrolling form style with a
        // trailing aligned column of labels next to a leading aligned column of
        // values". Both halves of that were visible here:
        //   • the label column tore the hash field's title out of the field and
        //     right-aligned it (wearing the field's monospaced font, since
        //     `.font` is an environment value), and pushed the Section header
        //     and footer into the value column as loose prose;
        //   • non-scrolling means the ping result and the Node Info rows simply
        //     fall out of reach in a short window, with no scrollbar.
        // `rnsSettingsContainer` gives macOS `Form` + `.formStyle(.grouped)` —
        // scrolling, grouped rows with leading labels and trailing controls —
        // and keeps iOS on `List` + `.insetGrouped`. Nothing here uses
        // `swipeActions`, the one thing that would rule out the macOS branch.
        //
        // This is a *pushed pane*, not a sheet, so it needs no macOS frame. The
        // Form-based sheets elsewhere in the app must NOT take this change
        // without one: non-scrolling columns style is what gives a macOS sheet
        // its intrinsic height, and `InterfaceDirectoryView` already records
        // what happens when that is lost ("pop-up opens collapsed with no
        // options").
        rnsSettingsContainer {
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
            if nodeInfo != nil { nodeInfo = nil }
            return
        }
        let next = NodeInfo(
            paths: transport.getPathTable().count,
            identities: transport.knownIdentities.count,
            interfaces: transport.interfaces.count
        )
        if nodeInfo != next { nodeInfo = next }
    }

    private var hexCount: Int { pingTarget.filter(\.isHexDigit).count }
    private var canPing: Bool { hexCount == 32 && stack.isRunning && !isPinging }

    private var pingSection: some View {
        Section {
            // `RNSHashField`, not `TextField(_:text:).rnsHashFieldStyle()`: the
            // first argument of that initializer is a *label*, and a Form on
            // macOS always places the label outside the field, using only a
            // `prompt` as in-field placeholder text. The container swap above
            // fixes the grouping; on its own it would still have left the hint
            // stranded in a column of its own.
            RNSHashField("Destination",
                         prompt: "32 hex characters",
                         compactPrompt: "Destination hash (32 hex chars)",
                         text: $pingTarget)
                .onChange(of: pingTarget) { _, new in
                    // Assign only when the filter actually changed something —
                    // writing the binding on every keystroke schedules a
                    // redundant update pass.
                    let filtered = String(new.filter(\.isHexDigit).prefix(32))
                    if filtered != new { pingTarget = filtered }
                    if pingResult != nil { pingResult = nil }
                }
                // Gives the Done key on iOS something to do, and matches the
                // Return behaviour of the default-action button below.
                // Previously `.submitLabel(.done)` from `rnsHashFieldStyle()`
                // labelled a key that was inert.
                .onSubmit { if canPing { Task { await ping() } } }

            // Live progress toward 32. The placeholder disappears the moment
            // typing starts (HIG ▸ Text fields), so this is what tells people
            // how far they have to go while pasting or correcting.
            if !pingTarget.isEmpty && hexCount != 32 {
                Text("\(hexCount)/32 hex characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                Task { await ping() }
            } label: {
                HStack(spacing: 6) {
                    if isPinging { ProgressView().controlSize(.small) }
                    Text(isPinging ? "Pinging…" : "Ping")
                }
                // The frame belongs on the *label*, inside the style. Outside
                // `.buttonStyle` it does not stretch the bezel — the style body
                // is `label.padding().background(…)`, and `.background` sizes to
                // its content, so a wider proposal just centres a content-sized
                // capsule in a box of inert space. Clicking the row anywhere but
                // the capsule would do nothing.
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            // HIG ▸ Buttons: "use a button that has a prominent visual style for
            // the most likely action in a view", and a primary button that
            // responds to Return "makes it easy for people to quickly confirm
            // their choice". Ping is the only action on this pane.
            //
            // This also changes iOS, where an unstyled Button fills the row and
            // a bordered-prominent one would otherwise collapse to a
            // content-sized capsule — hence the frame on the label above, which
            // keeps the ≥44 pt target the full-width row had.
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canPing)

            if let outcome = pingResult {
                Label {
                    Text(outcome.message)
                        .font(.callout.monospaced())
                        .foregroundStyle(outcome.tint)
                        // The failure message is a full sentence; let it wrap
                        // rather than truncate when the window is narrow.
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    // Decorative — the state is carried by the accessibility
                    // label below, matching PathRow's treatment of its hop glyph.
                    Image(systemName: outcome.symbol)
                        .foregroundStyle(outcome.tint)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(outcome.accessibilityPrefix))
                .accessibilityValue(Text(outcome.message))
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
                // The wide label/value gap under grouped style is the *correct*
                // native appearance — leading-aligned labels with trailing
                // controls is exactly how System Settings renders a row. No
                // `.fixedSize` or width frame is warranted.
                LabeledContent("Paths known")      { Text("\(info.paths)").foregroundStyle(.secondary) }
                LabeledContent("Identities known") { Text("\(info.identities)").foregroundStyle(.secondary) }
                LabeledContent("Interfaces")       { Text("\(info.interfaces)").foregroundStyle(.secondary) }
            } else {
                // Not an error — an unavailable-because-not-running state.
                Label("Stack not running", systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
            }
        }
        // Applied per-section rather than per-row: `monospacedDigit` is an
        // environment font trait, so it flows to the rows without needing three
        // call sites.
        .monospacedDigit()
        .rnsRow()
    }

    @MainActor
    private func ping() async {
        let hex = String(pingTarget.filter(\.isHexDigit).prefix(32))
        guard let hashData = Data(hexString: hex),
              let transport = stack.transport else {
            pingResult = .unreachable("Invalid hash")
            return
        }
        isPinging = true
        defer { isPinging = false }

        if transport.hasPath(to: hashData) {
            let hops = transport.getPathTable()
                .first { $0.destinationHash == hashData }
                .map { "\($0.hops) hop\($0.hops == 1 ? "" : "s")" } ?? "path known"
            pingResult = .reachable("Path exists (\(hops))")
        } else {
            try? transport.requestPath(for: hashData)
            try? await Task.sleep(for: .seconds(3))
            if transport.hasPath(to: hashData) {
                pingResult = .reachable("Path found after request")
            } else {
                pingResult = .unreachable("No path found (destination may be offline)")
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
