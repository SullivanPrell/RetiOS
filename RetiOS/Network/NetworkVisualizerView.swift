import SwiftUI
import ReticulumSwift

// MARK: - NetworkVisualizerView
//
// An interactive, live radial graph of this node, its active interfaces,
// and the destinations reachable through each — grouped by interface,
// ringed by hop-distance, and color-coded by connection type (TCP, UDP,
// AutoInterface, RNode/LoRa, I2P, …).
//
// Unlike a force-directed physics simulation (MeshChatX's vis-network
// approach), layout here is a deterministic radial placement recomputed
// on each refresh: "me" at the center, interfaces in a ring around it,
// and each interface's known destinations placed on concentric hop-rings
// beyond it — chained together wherever the local path table reveals the
// actual relay (so multi-hop routes draw as real chains, not a flat star).
// This keeps rendering snappy on mobile (no per-frame physics step) while
// surfacing more topology detail: hop distance, relay chains vs. inferred
// multi-hop spans, and which destinations have a currently-active link.
//
// Pinch to zoom, drag to pan, or use the on-screen +/−/reset controls.

struct NetworkVisualizerView: View {
    @EnvironmentObject var stack: StackController
    @State private var graph = NetworkGraph()
    @State private var selectedNodeID: String?
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var steadyPanOffset: CGSize = .zero
    @State private var pulse = false
    private let refreshInterval: TimeInterval = 4
    private let zoomRange: ClosedRange<CGFloat> = 0.55...4.5

    var body: some View {
        Group {
            if graph.nodes.count <= 1 {
                emptyState
            } else {
                graphCanvas
            }
        }
        .rnsScreenBackground()
        .onAppear {
            refresh()
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                refresh()
            }
        }
    }

    // MARK: Graph canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ringsLayer(size: geo.size)
                edgesLayer(size: geo.size)

                ForEach(graph.nodes) { node in
                    NodeBubble(node: node, isSelected: selectedNodeID == node.id, pulse: pulse)
                        .position(x: node.normPosition.x * geo.size.width,
                                  y: node.normPosition.y * geo.size.height)
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.2)) {
                                selectedNodeID = (selectedNodeID == node.id) ? nil : node.id
                            }
                        }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: node.normPosition)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(zoom)
            .offset(panOffset)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(SimultaneousGesture(zoomGesture, panGesture))
            .clipped()
        }
        .overlay(alignment: .topLeading) { legend.padding(12) }
        .overlay(alignment: .topTrailing) { zoomControls.padding(12) }
        .overlay(alignment: .bottom) {
            if let id = selectedNodeID, let node = graph.node(id) {
                NodeDetailBar(node: node, graph: graph)
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedNodeID)
    }

    // MARK: Zoom & pan

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in zoom = clampZoom(steadyZoom * value) }
            .onEnded { value in
                steadyZoom = clampZoom(steadyZoom * value)
                zoom = steadyZoom
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                panOffset = CGSize(width: steadyPanOffset.width + value.translation.width,
                                   height: steadyPanOffset.height + value.translation.height)
            }
            .onEnded { _ in steadyPanOffset = panOffset }
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }

    private func adjustZoom(by factor: CGFloat) {
        withAnimation(.snappy(duration: 0.2)) {
            steadyZoom = clampZoom(steadyZoom * factor)
            zoom = steadyZoom
        }
    }

    private func resetView() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            zoom = 1; steadyZoom = 1
            panOffset = .zero; steadyPanOffset = .zero
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button { adjustZoom(by: 1.35) } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .accessibilityLabel("Zoom in")
            Divider().frame(width: 28)
            Button { adjustZoom(by: 1 / 1.35) } label: {
                Image(systemName: "minus").frame(width: 28, height: 28)
            }
            .accessibilityLabel("Zoom out")
            Divider().frame(width: 28)
            Button { resetView() } label: {
                Image(systemName: "viewfinder").frame(width: 28, height: 28)
            }
            .accessibilityLabel("Reset view")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.rnsTextSecondary)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .buttonStyle(.plain)
    }

    // MARK: Hop-distance ring guides
    //
    // Drawn as native SwiftUI shapes/text — not a `Canvas` — for two reasons:
    // a `Canvas` rasterizes its content at the view's base size and the bitmap
    // is then visually scaled by `.scaleEffect(zoom)`, which goes blurry at high
    // zoom and illegible at low zoom (the "not responsive to zoom" + "hops
    // levels look buggy" reports); and `Canvas` redraws are instantaneous, with
    // no interpolation, so rings would visually "snap" between refreshes while
    // everything else glides. Native `Ellipse`/`Text` views re-render crisply at
    // any transform scale and their frame/position changes animate for free
    // inside the `withAnimation` that already wraps `graph` updates.

    private func ringsLayer(size: CGSize) -> some View {
        ZStack {
            ForEach(graph.displayedHopRings, id: \.self) { hops in
                let r = graph.hopRingRadii[hops] ?? 0
                let w = 2 * r * size.width
                let h = 2 * r * size.height

                Ellipse()
                    .stroke(Color.rnsTextMuted.opacity(0.15),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                    .frame(width: w, height: h)
                    .position(x: size.width / 2, y: size.height / 2)
                    .transition(.opacity)

                Text("\(hops) hop\(hops == 1 ? "" : "s")")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.rnsTextMuted.opacity(0.5))
                    .position(x: size.width / 2, y: size.height / 2 - h / 2 - 7)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Edges

    /// A straight segment between two points in canvas-space. Conforming to
    /// `Shape` (rather than drawing into a `Canvas`) gives it `animatableData`,
    /// so when an edge's endpoints move between refreshes — nodes resettling
    /// onto new hop-rings, relay chains re-resolving — SwiftUI interpolates the
    /// line smoothly instead of snapping, and it renders crisply at any zoom
    /// level instead of as a scaled-up rasterized bitmap.
    private struct EdgeShape: Shape {
        var from: CGPoint
        var to: CGPoint

        var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
            get { AnimatablePair(AnimatablePair(from.x, from.y), AnimatablePair(to.x, to.y)) }
            set {
                from = CGPoint(x: newValue.first.first, y: newValue.first.second)
                to = CGPoint(x: newValue.second.first, y: newValue.second.second)
            }
        }

        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: from)
            p.addLine(to: to)
            return p
        }
    }

    private func edgesLayer(size: CGSize) -> some View {
        ZStack {
            ForEach(graph.edges) { edge in
                if let from = graph.node(edge.from), let to = graph.node(edge.to) {
                    let highlighted = selectedNodeID != nil &&
                        (selectedNodeID == edge.from || selectedNodeID == edge.to)
                    let isInferred = edge.pathKind == .inferred
                    let baseOpacity: Double = highlighted ? 0.95 : (isInferred ? 0.28 : 0.40)
                    let lineWidth: CGFloat = highlighted ? 2.6 : (isInferred ? 1.2 : 1.5)

                    EdgeShape(from: CGPoint(x: from.normPosition.x * size.width, y: from.normPosition.y * size.height),
                              to: CGPoint(x: to.normPosition.x * size.width, y: to.normPosition.y * size.height))
                        .stroke(edge.connectionType.color.opacity(baseOpacity),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                                   dash: isInferred ? [6, 4] : []))
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Legend

    private var legend: some View {
        let usedTypes = Set(graph.edges.map(\.connectionType))
        let hasInferred = graph.edges.contains { $0.pathKind == .inferred }
        let hasActiveLinks = graph.nodes.contains {
            if case .destination(_, _, let active) = $0.kind { return active }
            return false
        }

        return VStack(alignment: .leading, spacing: 5) {
            ForEach(ConnectionType.allCases.filter(usedTypes.contains), id: \.self) { type in
                HStack(spacing: 6) {
                    Circle().fill(type.color).frame(width: 8, height: 8)
                    Text(type.label).font(.caption2).foregroundStyle(Color.rnsTextSecondary)
                }
            }
            if hasActiveLinks || hasInferred {
                Divider().frame(width: 110)
            }
            if hasActiveLinks {
                HStack(spacing: 6) {
                    Circle().strokeBorder(Color.rnsSuccess, lineWidth: 1.5).frame(width: 8, height: 8)
                    Text("Active link").font(.caption2).foregroundStyle(Color.rnsTextSecondary)
                }
            }
            if hasInferred {
                HStack(spacing: 6) {
                    dashedSwatch
                    Text("Multi-hop, relay unknown").font(.caption2).foregroundStyle(Color.rnsTextSecondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .opacity(usedTypes.isEmpty ? 0 : 1)
    }

    private var dashedSwatch: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(Color.rnsTextMuted),
                           style: StrokeStyle(lineWidth: 1.4, dash: [3, 2]))
        }
        .frame(width: 14, height: 8)
    }

    // MARK: Empty state

    private var emptyState: some View {
        RNSEmptyState(
            title: "No Network Topology Yet",
            systemImage: "point.3.connected.trianglepath.dotted",
            description: "The graph fills in as interfaces come online and paths to other destinations are discovered."
        )
    }

    // MARK: Refresh

    private func refresh() {
        guard let transport = stack.transport else { return }
        let next = NetworkGraph.build(transport: transport)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
            graph = next
        }
        if let id = selectedNodeID, graph.node(id) == nil {
            selectedNodeID = nil
        }
    }
}

// MARK: - Node bubble

private struct NodeBubble: View {
    let node: NetworkGraph.Node
    let isSelected: Bool
    let pulse: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if hasActiveLink {
                    Circle()
                        .stroke(Color.rnsSuccess.opacity(pulse ? 0.12 : 0.55), lineWidth: 2)
                        .frame(width: diameter + (pulse ? 16 : 6), height: diameter + (pulse ? 16 : 6))
                }
                Circle()
                    .fill(fillColor)
                    .frame(width: diameter, height: diameter)
                Image(systemName: iconName)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2))
            .shadow(color: fillColor.opacity(isSelected ? 0.65 : 0.3), radius: isSelected ? 9 : 3)

            Text(node.label)
                .font(.caption2.monospaced())
                .foregroundStyle(Color.rnsTextSecondary)
                .lineLimit(1)
                .frame(maxWidth: diameter + 56)
        }
        .scaleEffect(isSelected ? 1.08 : 1.0)
    }

    private var hasActiveLink: Bool {
        if case .destination(_, _, let active) = node.kind { return active }
        return false
    }

    private var diameter: CGFloat {
        switch node.kind {
        case .me:           return 46
        case .interface:    return 34
        case .destination:  return 22
        }
    }

    private var fillColor: Color {
        switch node.kind {
        case .me:                          return .rnsAccentBright
        case .interface(let type):         return type.color
        case .destination(let type, _, _): return type.color.opacity(0.78)
        }
    }

    private var iconName: String {
        switch node.kind {
        case .me:           return "antenna.radiowaves.left.and.right"
        case .interface:    return "point.3.connected.trianglepath.dotted"
        case .destination:  return "circle.fill"
        }
    }
}

// MARK: - Node detail bar

private struct NodeDetailBar: View {
    let node: NetworkGraph.Node
    let graph: NetworkGraph

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .destination(let type, let hops, let activeLink) = node.kind {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        if activeLink {
                            Image(systemName: "bolt.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.rnsSuccess)
                        }
                        Text(type.label).font(.caption2.bold()).foregroundStyle(type.color)
                    }
                    Text("\(hops) hop\(hops == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if case .interface(let type) = node.kind {
                let count = graph.edges.filter { $0.from == node.id }.count
                VStack(alignment: .trailing, spacing: 2) {
                    Text(type.label).font(.caption2.bold()).foregroundStyle(type.color)
                    Text("\(count) reachable")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var title: String {
        switch node.kind {
        case .me:          return "This Node"
        case .interface:   return node.label
        case .destination: return "Destination"
        }
    }

    private var subtitle: String {
        switch node.kind {
        case .me:                  return "center of the mesh view"
        case .interface(let type): return type.label + " interface"
        case .destination:         return node.fullID
        }
    }
}

// MARK: - NetworkGraph model

/// A snapshot of the locally-known mesh topology, laid out as normalized
/// (0...1) coordinates so the view can scale it to any canvas size.
struct NetworkGraph {
    struct Node: Identifiable {
        let id: String
        let label: String
        /// Full identifier (e.g. destination hash) for the detail bar — `label` is truncated.
        let fullID: String
        let kind: Kind
        var normPosition: CGPoint

        enum Kind {
            case me
            case interface(ConnectionType)
            case destination(ConnectionType, hops: UInt8, hasActiveLink: Bool)
        }
    }

    struct Edge: Identifiable {
        /// `.known` — a direct, single-hop link or a chain segment confirmed by
        /// matching the path table's `via` field to another known destination.
        /// `.inferred` — the destination is N hops away through this interface,
        /// but the relay chain isn't locally resolvable, so the edge spans the
        /// full distance directly (drawn dashed to mark it as a guess).
        enum PathKind { case known, inferred }

        let id: String
        let from: String
        let to: String
        let connectionType: ConnectionType
        let pathKind: PathKind
    }

    var nodes: [Node] = []
    var edges: [Edge] = []

    /// hop-count → normalized ring radius for *every* distinct hop level
    /// present in the path table. Stored on the graph (rather than recomputed
    /// by the view) so node placement and ring-guide rendering are always
    /// derived from the exact same map — they can never disagree about where
    /// a given hop level's ring sits.
    var hopRingRadii: [UInt8: CGFloat] = [:]

    /// The subset of `hopRingRadii`'s keys selected for on-canvas ring guides
    /// — see `NetworkGraph.pickDisplayRings`.
    var displayedHopRings: [UInt8] = []

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
}

extension NetworkGraph {
    private static let meID = "me"
    private static let interfaceRadius: CGFloat = 0.27
    private static let hopRingBase: CGFloat = 0.35
    private static let hopRingMax: CGFloat = 0.47
    /// Most ring guides we'll draw, regardless of how many distinct hop
    /// levels are present — keeps the canvas legible on a phone screen.
    private static let maxDisplayedRings = 5

    /// Maps each distinct hop count present to a normalized ring radius, using
    /// the *rank* of the value (its position in sorted order) rather than its
    /// raw magnitude, spread evenly across `[hopRingBase, hopRingMax]`.
    ///
    /// The previous formula (`base + (hops - 1) * step`, capped at `max`)
    /// caused every hop count beyond ~3 to collapse onto the same capped outer
    /// radius — e.g. 3-hop and 5-hop destinations would land on the exact same
    /// ring, which then drew two overlapping dashed circles with their "3 hops"
    /// / "5 hops" labels stacked illegibly on top of each other (the "display
    /// bugs with the hops levels" report). Rank-based spacing guarantees every
    /// distinct level present gets its own uniquely-positioned ring, however
    /// large or sparse the actual hop counts are.
    private static func ringRadii(forHopValues values: [UInt8]) -> [UInt8: CGFloat] {
        let distinct = Array(Set(values)).sorted()
        guard let nearest = distinct.first else { return [:] }
        guard distinct.count > 1 else { return [nearest: hopRingBase] }
        let step = (hopRingMax - hopRingBase) / CGFloat(distinct.count - 1)
        return Dictionary(uniqueKeysWithValues: distinct.enumerated().map { rank, hops in
            (hops, hopRingBase + CGFloat(rank) * step)
        })
    }

    /// Selects a legible subset of hop values to draw ring guides for. Every
    /// distinct hop level still gets its own unique radius for *layout*
    /// purposes (see `ringRadii` — nodes always land on a correctly-spaced
    /// ring), but drawing a guide circle and label for each one when many
    /// distinct levels are present would crowd the canvas and stack labels, so
    /// this samples evenly across the sorted range, always keeping the nearest
    /// and farthest rings as orientation anchors.
    private static func pickDisplayRings(from sortedDistinctHops: [UInt8]) -> [UInt8] {
        guard sortedDistinctHops.count > maxDisplayedRings else { return sortedDistinctHops }
        return (0..<maxDisplayedRings).map { i in
            let idx = Int((Double(i) / Double(maxDisplayedRings - 1)) * Double(sortedDistinctHops.count - 1))
            return sortedDistinctHops[idx]
        }
    }

    /// Builds a radial graph: "me" at center, a ring of active interfaces around
    /// it, and each interface's known destinations placed on concentric hop-rings
    /// beyond it. Where the path table's `via` field resolves to another known
    /// destination, segments chain together as real relay paths; otherwise a
    /// destination is still placed at its true hop-distance but its edge back to
    /// the interface is drawn as "inferred" (distance known, route unknown).
    static func build(transport: Transport) -> NetworkGraph {
        var nodes: [Node] = [Node(id: meID, label: "Me", fullID: "This node",
                                  kind: .me, normPosition: CGPoint(x: 0.5, y: 0.5))]
        var edges: [Edge] = []

        let interfaces = transport.interfaces
        guard !interfaces.isEmpty else { return NetworkGraph(nodes: nodes, edges: edges) }

        var entriesByInterface: [String: [PathEntryInfo]] = [:]
        var allHops: [UInt8] = []
        for entry in transport.getPathTable() {
            let hex = entry.destinationHash.map { String(format: "%02x", $0) }.joined()
            let viaHex = entry.via?.map { String(format: "%02x", $0) }.joined()
            entriesByInterface[entry.interfaceName, default: []]
                .append(PathEntryInfo(hashHex: hex, hops: entry.hops, viaHex: viaHex))
            allHops.append(entry.hops)
        }

        // Computed once, up front, and threaded through to both layout and the
        // ring guides — guarantees the two can never disagree about geometry.
        let radii = ringRadii(forHopValues: allHops)
        let displayedRings = pickDisplayRings(from: Array(radii.keys).sorted())

        let activeDestHashes = Set(
            transport.links.values
                .filter { $0.status == .active }
                .map { $0.destination.hexHash }
        )

        let ifaceCount = interfaces.count
        for (i, iface) in interfaces.enumerated() {
            let angle = angleFor(index: i, count: ifaceCount)
            let center = polarPoint(angle: angle, radius: interfaceRadius)
            let connType = ConnectionType(interfaceTypeName: String(describing: type(of: iface)),
                                          name: iface.name)
            let ifaceID = "iface:\(iface.name)"

            nodes.append(Node(id: ifaceID, label: iface.name, fullID: iface.name,
                              kind: .interface(connType), normPosition: center))
            edges.append(Edge(id: "\(meID)->\(ifaceID)", from: meID, to: ifaceID,
                              connectionType: connType, pathKind: .known))

            let entries = entriesByInterface[iface.name] ?? []
            guard !entries.isEmpty else { continue }

            let chains = buildChains(from: entries)
            let totalLeaves = chains.reduce(0) { $0 + $1.leafCount }
            guard totalLeaves > 0 else { continue }

            // Fan this interface's whole subtree across an angular sector centered
            // on its own direction, subdivided per chain by leaf count so dense
            // branches get proportionally more angular room.
            let sectorWidth = min(2 * .pi / Double(ifaceCount) * 0.92, .pi * 1.7)
            var cursor = angle - sectorWidth / 2
            for chain in chains {
                let span = sectorWidth * (Double(chain.leafCount) / Double(totalLeaves))
                let rootEdgeKind: Edge.PathKind = chain.hops <= 1 ? .known : .inferred
                layoutChain(chain, angleStart: cursor, angleEnd: cursor + span,
                            parentID: ifaceID, connType: connType, incomingEdgeKind: rootEdgeKind,
                            activeHashes: activeDestHashes, ringRadii: radii, into: &nodes, edges: &edges)
                cursor += span
            }
        }

        return NetworkGraph(nodes: nodes, edges: edges, hopRingRadii: radii, displayedHopRings: displayedRings)
    }

    // MARK: Relay-chain reconstruction

    private struct PathEntryInfo {
        let hashHex: String
        let hops: UInt8
        let viaHex: String?
    }

    private struct ChainNode {
        let hashHex: String
        let hops: UInt8
        let children: [ChainNode]

        var leafCount: Int { children.isEmpty ? 1 : children.reduce(0) { $0 + $1.leafCount } }
    }

    /// Reconstructs known multi-hop relay chains by matching each entry's `via`
    /// (the next-hop transport ID Reticulum recorded for that path) to another
    /// entry's destination hash with a strictly smaller hop count. Matches chain
    /// together as parent → child; entries with no resolvable relay become chain
    /// roots, still placed at their true hop-distance ring.
    private static func buildChains(from entries: [PathEntryInfo]) -> [ChainNode] {
        var hopsByHash: [String: UInt8] = [:]
        for e in entries { hopsByHash[e.hashHex] = e.hops }

        var childrenOf: [String: [String]] = [:]
        var hasParent: Set<String> = []
        for e in entries {
            guard let viaHex = e.viaHex,
                  let viaHops = hopsByHash[viaHex],
                  viaHops < e.hops else { continue }
            childrenOf[viaHex, default: []].append(e.hashHex)
            hasParent.insert(e.hashHex)
        }

        func build(_ hashHex: String) -> ChainNode {
            ChainNode(hashHex: hashHex,
                      hops: hopsByHash[hashHex] ?? 1,
                      children: (childrenOf[hashHex] ?? []).map(build))
        }

        // Hop counts strictly increase parent → child, so this recursion can't cycle.
        return entries
            .filter { !hasParent.contains($0.hashHex) }
            .sorted { $0.hops < $1.hops }
            .map { build($0.hashHex) }
    }

    private static func layoutChain(_ chain: ChainNode, angleStart: Double, angleEnd: Double,
                                    parentID: String, connType: ConnectionType,
                                    incomingEdgeKind: Edge.PathKind, activeHashes: Set<String>,
                                    ringRadii: [UInt8: CGFloat],
                                    into nodes: inout [Node], edges: inout [Edge]) {
        let angle = (angleStart + angleEnd) / 2
        let r = ringRadii[chain.hops] ?? hopRingMax
        let raw = polarPoint(angle: angle, radius: r)
        let pos = CGPoint(x: min(max(raw.x, 0.05), 0.95), y: min(max(raw.y, 0.05), 0.95))
        let id = "dest:\(chain.hashHex)"
        let active = activeHashes.contains(chain.hashHex)

        nodes.append(Node(id: id, label: String(chain.hashHex.prefix(6)), fullID: chain.hashHex,
                          kind: .destination(connType, hops: chain.hops, hasActiveLink: active),
                          normPosition: pos))
        edges.append(Edge(id: "\(parentID)->\(id)", from: parentID, to: id,
                          connectionType: connType, pathKind: incomingEdgeKind))

        guard !chain.children.isEmpty else { return }
        let totalLeaves = chain.children.reduce(0) { $0 + $1.leafCount }
        var cursor = angleStart
        let span = angleEnd - angleStart
        for child in chain.children {
            let childSpan = span * (Double(child.leafCount) / Double(totalLeaves))
            // A resolved chain segment is always a "known" relay hop.
            layoutChain(child, angleStart: cursor, angleEnd: cursor + childSpan,
                        parentID: id, connType: connType, incomingEdgeKind: .known,
                        activeHashes: activeHashes, ringRadii: ringRadii, into: &nodes, edges: &edges)
            cursor += childSpan
        }
    }

    private static func angleFor(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return (Double(index) / Double(count)) * 2 * .pi - .pi / 2
    }

    private static func polarPoint(angle: Double, radius: CGFloat) -> CGPoint {
        // Keep the trig in `Double` throughout: mixing `cos(angle)` (Double) with
        // a `CGFloat` operand makes `cos`/`sin` overload resolution ambiguous on
        // newer toolchains. Convert the radius once, compute in Double.
        let r = Double(radius)
        return CGPoint(x: 0.5 + cos(angle) * r, y: 0.5 + sin(angle) * r)
    }
}

// MARK: - ConnectionType

/// Connection-type classification driving edge/node color and the legend —
/// derived from the interface's concrete Swift type for precise grouping
/// (more granular than the name-substring heuristic used elsewhere in the UI).
enum ConnectionType: CaseIterable, Hashable {
    case tcp, udp, auto, backbone, local, lora, i2p, serial, other

    init(interfaceTypeName: String, name: String) {
        switch interfaceTypeName {
        case "TCPClientInterface", "TCPServerInterface": self = .tcp
        case "UDPInterface":                             self = .udp
        case "AutoInterface":                            self = .auto
        case "BackboneInterface":                        self = .backbone
        case "LocalInterface":                           self = .local
        case "RNodeInterface", "RNodeMultiInterface":    self = .lora
        case "I2PInterface":                             self = .i2p
        case "SerialInterface", "KISSInterface", "AX25KISSInterface": self = .serial
        default:
            // Fall back to a name heuristic for custom/unknown interface implementations.
            let n = name.lowercased()
            if n.contains("auto")            { self = .auto }
            else if n.contains("tcp")        { self = .tcp }
            else if n.contains("udp")        { self = .udp }
            else if n.contains("rnode") || n.contains("lora") || n.contains("ble") { self = .lora }
            else if n.contains("i2p")        { self = .i2p }
            else if n.contains("local")      { self = .local }
            else if n.contains("serial") || n.contains("kiss") { self = .serial }
            else                             { self = .other }
        }
    }

    var color: Color {
        switch self {
        case .tcp:      return .rnsAccent
        case .udp:      return Color(red: 0.62, green: 0.42, blue: 0.93)
        case .auto:     return .rnsInfo
        case .backbone: return Color(red: 0.42, green: 0.52, blue: 0.96)
        case .local:    return .rnsSuccess
        case .lora:     return .rnsWarning
        case .i2p:      return Color(red: 0.74, green: 0.32, blue: 0.82)
        case .serial:   return Color(red: 0.55, green: 0.72, blue: 0.55)
        case .other:    return .rnsTextMuted
        }
    }

    var label: String {
        switch self {
        case .tcp:      return "TCP"
        case .udp:      return "UDP"
        case .auto:     return "AutoInterface"
        case .backbone: return "Backbone"
        case .local:    return "Local"
        case .lora:     return "RNode / LoRa"
        case .i2p:      return "I2P"
        case .serial:   return "Serial / KISS"
        case .other:    return "Other"
        }
    }
}
