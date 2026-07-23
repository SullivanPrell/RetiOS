import SwiftUI
import ReticulumSwift

// MARK: - NetworkVisualizerView
//
// A live radial view of this node, its active interfaces, and how much of the
// mesh sits behind each one at what hop distance.
//
// ## Why this is a *distribution*, not a node-per-destination graph
//
// The previous version drew one bubble per path-table entry. That is
// arithmetically impossible to read at real-world scale, and the failure is not
// a tuning problem:
//
//   With 341 known paths over 3 interfaces, each interface fanned ~113
//   destinations across a 110° sector at a ~177 pt radius. That is 3.0 pt of
//   arc per node — against a 22 pt bubble and a ~78 pt label. A 7× overlap on
//   the circles alone, which rendered as two solid crescent-shaped smears of
//   overlapping glyphs, and zooming only scaled the smear.
//
//   Spreading the rings across the whole canvas instead of the old [0.35, 0.47]
//   band only reaches 7.9 pt per node — still 3× overlapped. A phone-sized
//   canvas holds roughly 60 nodes on a full circle at legible spacing. No
//   layout can draw 341.
//
// So destinations are aggregated into per-(interface, hop-band) clusters. The
// bubble count is now bounded by `interfaces × HopBand.allCases.count`
// (≤ 4 per interface) regardless of whether the path table holds 3 entries or
// 3000, and the thing the view shows — how reachability is distributed across
// interfaces and hop distance — is what no list can show. The Paths tab in this
// same screen already enumerates every row for anyone who wants the individual
// hashes; tapping a cluster here opens exactly that list, scoped to the cluster.
//
// ## Why there are no relay chains any more
//
// The old code reconstructed multi-hop relay chains by matching a path entry's
// `via` to another entry's destination hash. That could never match:
// `PathTableEntry.via` is `nextHopTransportID` (Transport.swift), and a
// transport ID is a 16-byte random per-node instance identifier — never a
// destination hash. `hopsByHash[viaHex]` was therefore always nil, every entry
// became a parentless chain root, and the graph was always a flat depth-2 star.
// The chain-reconstruction code was dead, and the header comment promising
// "multi-hop routes draw as real chains" described something that never
// rendered. The local path table simply does not contain the intermediate hops,
// so the honest thing to draw is distance, not route.
//
// Pinch to zoom, drag to pan, or use the on-screen +/−/reset controls.

struct NetworkVisualizerView: View {
    @Environment(StackController.self) private var stack
    @State private var graph = NetworkGraph()
    @State private var selectedNodeID: String?
    @State private var clusterDetail: NetworkGraph.Node?
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
        .sheet(item: $clusterDetail) { node in
            ClusterDetailSheet(node: node)
        }
    }

    // MARK: Graph canvas

    /// Vertical space reserved at the bottom for the legend / detail bar.
    ///
    /// The graph lays out inside `geo.size.height - bottomReserve` rather than
    /// the whole canvas. Without it the outermost band's bubbles land under the
    /// overlay strip: with two interfaces, `angleFor(1, 2)` is exactly `.pi/2`,
    /// so the second spoke points straight down and its far cluster sits at
    /// y ≈ 0.92 of the canvas — behind an opaque `.ultraThinMaterial` panel.
    private let bottomReserve: CGFloat = 76

    private var graphCanvas: some View {
        GeometryReader { geo in
            // Everything maps into this, not `geo.size`.
            let canvas = CGSize(width: geo.size.width,
                                height: max(geo.size.height - bottomReserve, 160))
            ZStack(alignment: .topLeading) {
                // Behind everything: a hit-testable blank that clears the
                // selection. Without it there was no way to *deselect* — the
                // bubbles were the only hit targets, so the detail bar stayed
                // pinned to whatever was last tapped for the life of the view.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { selectedNodeID = nil } }

                // Rings and edges are decorative scaffolding — hidden from
                // VoiceOver so it lands on the nodes themselves.
                ringsLayer(size: canvas)
                    .accessibilityHidden(true)
                edgesLayer(size: canvas)
                    .accessibilityHidden(true)

                ForEach(graph.nodes) { node in
                    NodeBubble(node: node,
                               isSelected: selectedNodeID == node.id,
                               pulse: pulse)
                        // Every bubble is drawn smaller than the 44 pt the HIG
                        // asks of a tap target — the smallest is 24 pt — so the
                        // frame pads the target out without changing the art.
                        // `contentShape` then makes the whole padded box
                        // tappable rather than just the circle's pixels.
                        .frame(minWidth: node.kind.hitDiameter,
                               minHeight: node.kind.hitDiameter)
                        .contentShape(Rectangle())
                        .onTapGesture { activate(node) }
                        .position(x: node.normPosition.x * canvas.width,
                                  y: node.normPosition.y * canvas.height)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: node.normPosition)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityLabel(for: node))
                        .accessibilityAddTraits(selectedNodeID == node.id ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { activate(node) }
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
        .overlay(alignment: .topTrailing) { zoomControls.padding(12) }
        .overlay(alignment: .bottom) {
            // Legend and detail bar share the bottom slot rather than the legend
            // sitting over the graph. At the old top-leading position it covered
            // the canvas the graph now actually uses.
            Group {
                if let id = selectedNodeID, let node = graph.node(id) {
                    NodeDetailBar(node: node, graph: graph)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    legend
                }
            }
            .padding(12)
            // Both are purely informational — neither carries a control. Left
            // hit-testable they swallow taps aimed at whatever is behind them,
            // which is why `bottomReserve` alone is not the whole fix.
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(graphSummary)
        .animation(.snappy, value: selectedNodeID)
    }

    /// Tap handling for a bubble.
    ///
    /// A cluster ALWAYS opens its list — it never toggles off. The toggle was a
    /// trap: the sheet could only open on the branch that had just *assigned*
    /// `node.id`, so the second tap on a selected cluster deselected it and
    /// opened nothing, while the detail bar sat there reading "tap again to
    /// list them" and the VoiceOver label promised "opens the list". Dismissing
    /// the sheet leaves the node selected, so that second tap is exactly the one
    /// a user makes to get the list back. Deselecting is the background tap's
    /// job, which is a bigger target than any bubble.
    private func activate(_ node: NetworkGraph.Node) {
        if case .cluster = node.kind {
            withAnimation(.snappy(duration: 0.2)) { selectedNodeID = node.id }
            clusterDetail = node
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            selectedNodeID = (selectedNodeID == node.id) ? nil : node.id
        }
    }

    private var graphSummary: String {
        let dests = graph.nodes.reduce(0) { total, node in
            switch node.kind {
            case .cluster(_, _, let count, _): return total + count
            case .destination:                 return total + 1
            default:                           return total
            }
        }
        let ifaces = graph.nodes.filter { if case .interface = $0.kind { return true }; return false }.count
        return "Network graph: \(ifaces) interface\(ifaces == 1 ? "" : "s"), \(dests) known destination\(dests == 1 ? "" : "s")"
    }

    /// VoiceOver description for a graph node (the bubbles are otherwise
    /// unlabelled shapes).
    private func accessibilityLabel(for node: NetworkGraph.Node) -> String {
        switch node.kind {
        case .me:
            return "This node, \(node.label)"
        case .interface(let type):
            let reachable = node.members.count
            return "\(type.label) interface \(node.label), \(reachable) destination\(reachable == 1 ? "" : "s") reachable"
        case .cluster(let type, let band, let count, let active):
            let activePart = active > 0 ? ", \(active) with an active link" : ""
            return "\(count) destination\(count == 1 ? "" : "s") \(band.spokenLabel) over \(type.label)\(activePart). Opens the list."
        case .destination(let type, let hops, let active):
            return "\(type.label) destination \(node.label), \(hops) hop\(hops == 1 ? "" : "s")\(active ? ", active link" : "")"
        }
    }

    // MARK: Zoom & pan

    private var zoomGesture: some Gesture {
        // MagnifyGesture (iOS 17 / macOS 14) replaces the deprecated
        // MagnificationGesture; its value is `.magnification`.
        MagnifyGesture()
            .onChanged { value in zoom = clampZoom(steadyZoom * value.magnification) }
            .onEnded { value in
                steadyZoom = clampZoom(steadyZoom * value.magnification)
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
            // 44×44 hit targets (HIG minimum) even though the glyphs stay small.
            Button { adjustZoom(by: 1.35) } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Zoom in")
            Divider().frame(width: 44)
            Button { adjustZoom(by: 1 / 1.35) } label: {
                Image(systemName: "minus").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Zoom out")
            Divider().frame(width: 44)
            Button { resetView() } label: {
                Image(systemName: "viewfinder").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Reset view")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.rnsTextSecondary)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .buttonStyle(.plain)
    }

    // MARK: Hop-band ring guides
    //
    // Drawn as native SwiftUI shapes/text — not a `Canvas` — because a `Canvas`
    // rasterizes its content at the view's base size and the bitmap is then
    // visually scaled by `.scaleEffect(zoom)`, going blurry at high zoom and
    // illegible at low zoom. Native `Ellipse`/`Text` re-render crisply at any
    // transform scale. With bands rather than one ring per distinct hop count
    // there are now at most four of them, so the old rank-based ring packing
    // (and the label-stacking it was working around) is gone entirely.
    //
    // The rings are ellipses, not circles: normalized positions are scaled by
    // width and height independently so the layout fills a phone's tall canvas
    // instead of wasting the vertical thirds a circle inscribed in it would.
    // Each band's ring is drawn and labelled, so "which band is this" is read
    // off the caption rather than judged by eye from the distance to centre.

    private func ringsLayer(size: CGSize) -> some View {
        ZStack {
            ForEach(graph.occupiedBands, id: \.self) { band in
                let r = band.radius
                let w = 2 * r * size.width
                let h = 2 * r * size.height

                Ellipse()
                    .stroke(Color.rnsTextMuted.opacity(0.15),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                    .frame(width: w, height: h)
                    .position(x: size.width / 2, y: size.height / 2)
                    .transition(.opacity)

                // Placed in the widest gap between spokes rather than at the top
                // of the ring, which is always where interface 0's bubbles are.
                let p = NetworkGraph.captionPoint(angle: graph.captionAngle, radius: r)
                Text(band.label)
                    .font(.caption2)
                    .foregroundStyle(Color.rnsTextMuted.opacity(0.75))
                    .padding(.horizontal, 4)
                    // A scrim, so the caption stays legible where the dashed
                    // ring passes behind it.
                    .background(Color.rnsCanvas.opacity(0.75), in: Capsule())
                    .position(x: p.x * size.width, y: p.y * size.height)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Edges

    /// A straight segment between two points in canvas-space. Conforming to
    /// `Shape` (rather than drawing into a `Canvas`) gives it `animatableData`,
    /// so when an edge's endpoints move between refreshes SwiftUI interpolates
    /// the line smoothly instead of snapping, and it renders crisply at any zoom
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
        let usedTypes = ConnectionType.allCases.filter(Set(graph.edges.map(\.connectionType)).contains)
        let hasInferred = graph.edges.contains { $0.pathKind == .inferred }
        let hasActiveLinks = graph.nodes.contains { node in
            switch node.kind {
            case .cluster(_, _, _, let active):  return active > 0
            case .destination(_, _, let active): return active
            default:                             return false
            }
        }

        // Horizontal and wrapping, so it reads as a caption strip under the
        // graph instead of a panel sitting on top of it.
        return ViewThatFits(in: .horizontal) {
            legendRow(usedTypes, hasActiveLinks: hasActiveLinks, hasInferred: hasInferred)
            // Types alone when the full strip does not fit — the two state keys
            // are the first thing worth dropping on a narrow phone.
            legendRow(usedTypes, hasActiveLinks: false, hasInferred: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(usedTypes.isEmpty ? 0 : 1)
    }

    private func legendRow(_ types: [ConnectionType],
                           hasActiveLinks: Bool,
                           hasInferred: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(types, id: \.self) { type in
                HStack(spacing: 5) {
                    // The same per-type glyph the bubbles use, so the legend
                    // keys on shape and not only on colour.
                    Image(systemName: type.glyph)
                        .font(.caption2)
                        .foregroundStyle(type.color)
                    Text(type.label).font(.caption2).foregroundStyle(Color.rnsTextSecondary)
                }
            }
            if hasActiveLinks {
                HStack(spacing: 5) {
                    Circle().strokeBorder(Color.rnsSuccess, lineWidth: 1.5).frame(width: 8, height: 8)
                    Text("Active link").font(.caption2).foregroundStyle(Color.rnsTextSecondary)
                }
            }
            if hasInferred {
                HStack(spacing: 5) {
                    dashedSwatch
                    Text("Route unknown").font(.caption2).foregroundStyle(Color.rnsTextSecondary)
                }
            }
        }
        .lineLimit(1)
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
        let live = stack.transport.map(NetworkGraph.build(transport:))
        // `-stackOffline YES` registers no interfaces, so the live graph is
        // empty and `scripts/mac-screens.sh` could only ever photograph the
        // empty state. The demo topology drives the exact same
        // `build(interfaces:)` the real one does — see `NetworkGraph.demo`.
        guard let next = (live?.nodes.count ?? 0) > 1 ? live : NetworkGraph.demo ?? live else { return }

        withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
            graph = next
        }
        if let id = selectedNodeID, graph.node(id) == nil {
            selectedNodeID = nil
        }
    }
}

// MARK: - Hop bands

/// Hop distance, bucketed.
///
/// Bands rather than one ring per distinct hop count. The path table here holds
/// hop values from 1 to 27+, and giving each its own ring produced up to a dozen
/// concentric dashed circles with stacked captions in the ~90 pt of usable
/// radius a phone canvas has. Four bands fit with ~30 pt between rings, and
/// "how far away" at this granularity is what anyone is actually reading off a
/// topology view — the exact hop count of a single destination is in the
/// cluster's detail list, and in the Paths tab.
enum HopBand: Int, CaseIterable, Hashable, Comparable {
    case direct = 0   // 0–1 hops
    case near   = 1   // 2–3
    case mid    = 2   // 4–7
    case far    = 3   // 8+

    init(hops: UInt8) {
        switch hops {
        case 0...1:  self = .direct
        case 2...3:  self = .near
        case 4...7:  self = .mid
        default:     self = .far
        }
    }

    static func < (lhs: HopBand, rhs: HopBand) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Normalized ring radius. Spread across [0.23, 0.47] — the old layout
    /// packed every level into [0.35, 0.47], the outer quarter of the canvas,
    /// which is why the centre of the graph was empty while its rim was a smear.
    /// 0.47 is very close to the 0.5 that reaches the canvas edge.
    /// Ring radius as a fraction of the canvas, where 0.5 reaches its edge.
    ///
    /// The old layout packed every level into [0.35, 0.47] — the outer quarter
    /// of the canvas — which is why the middle of the graph was empty while its
    /// rim was a smear. The outer bound stops at 0.42 rather than filling the
    /// space: a cluster bubble is up to 48 pt across, so a centre placed any
    /// closer to the edge gets its outer half sheared off. `polarPoint` applies
    /// no clamp, deliberately — the old code's `min(max(raw, 0.05), 0.95)`
    /// silently collapsed distinct positions onto the same edge point, so the
    /// radii themselves have to be the thing that keeps nodes on screen.
    var radius: CGFloat { 0.20 + CGFloat(rawValue) * 0.0733 }

    var label: String {
        switch self {
        case .direct: return "direct"
        case .near:   return "2–3 hops"
        case .mid:    return "4–7 hops"
        case .far:    return "8+ hops"
        }
    }

    /// VoiceOver reads "2–3" as a range badly; spell it.
    var spokenLabel: String {
        switch self {
        case .direct: return "directly reachable"
        case .near:   return "2 to 3 hops away"
        case .mid:    return "4 to 7 hops away"
        case .far:    return "8 or more hops away"
        }
    }
}

// MARK: - NetworkGraph model

/// A snapshot of the locally-known mesh topology, laid out as normalized
/// (0...1) coordinates so the view can scale it to any canvas size.
struct NetworkGraph {
    /// One destination behind a cluster — what the cluster's detail sheet lists.
    struct Member: Identifiable, Hashable {
        let hashHex: String
        let hops: UInt8
        let lastHeard: Date
        let hasActiveLink: Bool
        var id: String { hashHex }
    }

    struct Node: Identifiable {
        let id: String
        let label: String
        /// Full identifier (e.g. destination hash) for the detail bar — `label`
        /// is truncated.
        let fullID: String
        let kind: Kind
        /// The destinations this node stands for. Empty for `.me`; the whole
        /// subtree for `.interface`; the cluster's contents for `.cluster`.
        let members: [Member]
        var normPosition: CGPoint

        enum Kind {
            case me
            case interface(ConnectionType)
            /// An aggregate of `count` destinations reachable over this
            /// interface within one hop band, `activeCount` of which currently
            /// hold an active link.
            case cluster(ConnectionType, band: HopBand, count: Int, activeCount: Int)
            case destination(ConnectionType, hops: UInt8, hasActiveLink: Bool)

            var diameter: CGFloat {
                switch self {
                case .me:          return 46
                case .interface:   return 34
                case .destination: return 24
                // Sized by how much of the mesh it stands for, but on a log
                // scale and clamped: a linear map would make a 300-member
                // cluster twelve times the diameter of a 25-member one and run
                // it off the canvas.
                case .cluster(_, _, let count, _):
                    let t = min(1, log2(Double(max(count, 1))) / log2(256))
                    return 28 + 20 * CGFloat(t)
                }
            }

            /// The tap target, which is deliberately larger than the drawn
            /// bubble: HIG asks for at least 44 pt, and every bubble here is
            /// smaller than that.
            var hitDiameter: CGFloat { max(diameter, 44) }
        }
    }

    struct Edge: Identifiable {
        /// `.known` — a direct link to a destination reachable in one hop.
        /// `.inferred` — the destinations are N hops away through this
        /// interface, but the local path table records only the next-hop
        /// *transport ID*, never the intermediate destinations, so the route is
        /// genuinely unknown here. Drawn dashed to say so.
        enum PathKind { case known, inferred }

        let id: String
        let from: String
        let to: String
        let connectionType: ConnectionType
        let pathKind: PathKind
    }

    /// `let`, not `var`: `indexByID` is derived once in `init`, so a property
    /// that could be reassigned afterwards would silently desynchronise the map
    /// from `nodes` — and `node(_:)` would start returning nil for real nodes,
    /// so edges would vanish rather than crash. Nothing mutates a graph in
    /// place (`refresh()` whole-assigns), so this costs nothing and turns the
    /// invariant into a compile-time guarantee.
    let nodes: [Node]
    let edges: [Edge]
    /// The bands that actually contain something, for the ring guides.
    let occupiedBands: [HopBand]

    /// Where on each ring to put its caption, in radians.
    ///
    /// The midpoint of the widest angular gap between spokes. Captions used to
    /// be pinned to the top of the ring, but `angleFor(index: 0, count:)` is
    /// `-.pi/2` for *every* count — interface 0's spoke always runs straight up
    /// — so every caption was drawn 9 pt above the centre of one of that
    /// spoke's bubbles, i.e. inside it, since even the smallest bubble has a
    /// 12 pt radius. The captions were painted, then covered.
    let captionAngle: Double

    /// id → index into `nodes`. `node(_:)` was `nodes.first { $0.id == id }`,
    /// and `edgesLayer` calls it twice per edge inside `ForEach(graph.edges)`.
    private let indexByID: [String: Int]

    init(nodes: [Node] = [], edges: [Edge] = [], occupiedBands: [HopBand] = [],
         captionAngle: Double = .pi / 2) {
        self.nodes = nodes
        self.edges = edges
        self.occupiedBands = occupiedBands
        self.captionAngle = captionAngle
        self.indexByID = Dictionary(
            nodes.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func node(_ id: String) -> Node? {
        guard let i = indexByID[id] else { return nil }
        return nodes[i]
    }
}

extension NetworkGraph {
    private static let meID = "me"
    private static let interfaceRadius: CGFloat = 0.13
    /// Below this, a band's destinations are drawn individually instead of as a
    /// cluster — there is no point hiding two hashes behind a "2" bubble the
    /// user then has to tap.
    private static let clusterThreshold = 3

    /// One interface and everything reachable through it — the only input the
    /// layout needs.
    ///
    /// Extracted so `build(interfaces:)` is a pure function of plain values
    /// rather than of a live `Transport`. That is what makes the layout
    /// unit-testable (its whole point is a bound on node count at scale, which
    /// is worth asserting) and what lets the DEBUG demo topology drive the same
    /// code path the real one does.
    struct InterfaceInput {
        let name: String
        let type: ConnectionType
        let members: [Member]
    }

    static func build(transport: Transport) -> NetworkGraph {
        let activeDestHashes = Set(
            transport.links.values
                .filter { $0.status == .active }
                .map { $0.destination.hexHash }
        )

        var membersByInterface: [String: [Member]] = [:]
        for entry in transport.getPathTable() {
            let hex = entry.destinationHash.map { String(format: "%02x", $0) }.joined()
            membersByInterface[entry.interfaceName, default: []].append(
                Member(hashHex: hex,
                       hops: entry.hops,
                       lastHeard: entry.lastHeard,
                       hasActiveLink: activeDestHashes.contains(hex))
            )
        }

        return build(interfaces: transport.interfaces.map { iface in
            InterfaceInput(name: iface.name,
                           type: ConnectionType(interfaceTypeName: String(describing: type(of: iface)),
                                                name: iface.name),
                           members: membersByInterface[iface.name] ?? [])
        })
    }

    /// Builds the graph: "me" at centre, a ring of interfaces around it, and
    /// along each interface's spoke one bead per occupied hop band. A band
    /// holding fewer than `clusterThreshold` destinations draws them
    /// individually; anything larger becomes a single cluster bubble labelled
    /// with its count and openable as a list.
    ///
    /// The node count this produces is bounded by
    /// `1 + interfaces × (1 + HopBand.allCases.count × clusterThreshold)`
    /// — i.e. it does not grow with the size of the path table. That bound is
    /// the entire point of the rewrite; see the file header for the arithmetic
    /// showing why a node-per-destination layout cannot be made legible.
    static func build(interfaces: [InterfaceInput]) -> NetworkGraph {
        var nodes: [Node] = [Node(id: meID, label: "Me", fullID: "This node",
                                  kind: .me, members: [], normPosition: CGPoint(x: 0.5, y: 0.5))]
        var edges: [Edge] = []

        guard !interfaces.isEmpty else { return NetworkGraph(nodes: nodes, edges: edges) }

        var occupied: Set<HopBand> = []
        let ifaceCount = interfaces.count

        for (i, iface) in interfaces.enumerated() {
            let angle = angleFor(index: i, count: ifaceCount)
            let connType = iface.type
            let ifaceID = "iface:\(iface.name)"
            let members = iface.members

            nodes.append(Node(id: ifaceID, label: iface.name, fullID: iface.name,
                              kind: .interface(connType), members: members,
                              normPosition: polarPoint(angle: angle, radius: interfaceRadius)))
            edges.append(Edge(id: "\(meID)->\(ifaceID)", from: meID, to: ifaceID,
                              connectionType: connType, pathKind: .known))

            guard !members.isEmpty else { continue }

            let byBand = Dictionary(grouping: members) { HopBand(hops: $0.hops) }
            var previousID = ifaceID

            for band in HopBand.allCases {
                guard let bandMembers = byBand[band], !bandMembers.isEmpty else { continue }
                occupied.insert(band)

                // Beads are chained outward along the spoke rather than each
                // drawn back to the interface: collinear duplicate strokes
                // otherwise stack into one over-dark line. Only the first
                // segment is a confirmed direct link; everything past the
                // direct band is dashed, which is the legend's "route unknown".
                let edgeKind: Edge.PathKind = (band == .direct && previousID == ifaceID) ? .known : .inferred

                if bandMembers.count < clusterThreshold {
                    // Few enough to show individually. Fan them across a small
                    // arc centred on the spoke so they do not sit on top of
                    // each other.
                    let spread = 0.14 * Double(bandMembers.count - 1)
                    for (j, member) in bandMembers.sorted(by: { $0.hashHex < $1.hashHex }).enumerated() {
                        let a = angle - spread / 2 + 0.14 * Double(j)
                        let id = "dest:\(member.hashHex)"
                        nodes.append(Node(id: id,
                                          label: String(member.hashHex.prefix(6)),
                                          fullID: member.hashHex,
                                          kind: .destination(connType, hops: member.hops,
                                                             hasActiveLink: member.hasActiveLink),
                                          members: [member],
                                          normPosition: polarPoint(angle: a, radius: band.radius)))
                        edges.append(Edge(id: "\(previousID)->\(id)", from: previousID, to: id,
                                          connectionType: connType, pathKind: edgeKind))
                    }
                    // Chain onward from the first of them, so a later band still
                    // attaches to something on this spoke.
                    if let first = bandMembers.sorted(by: { $0.hashHex < $1.hashHex }).first {
                        previousID = "dest:\(first.hashHex)"
                    }
                } else {
                    let id = "cluster:\(iface.name):\(band.rawValue)"
                    let activeCount = bandMembers.filter(\.hasActiveLink).count
                    nodes.append(Node(id: id,
                                      label: "\(bandMembers.count)",
                                      fullID: "\(bandMembers.count) destinations, \(band.label)",
                                      kind: .cluster(connType, band: band,
                                                     count: bandMembers.count,
                                                     activeCount: activeCount),
                                      members: bandMembers.sorted { $0.hops < $1.hops },
                                      normPosition: polarPoint(angle: angle, radius: band.radius)))
                    edges.append(Edge(id: "\(previousID)->\(id)", from: previousID, to: id,
                                      connectionType: connType, pathKind: edgeKind))
                    previousID = id
                }
            }
        }

        return NetworkGraph(nodes: nodes, edges: edges,
                            occupiedBands: HopBand.allCases.filter(occupied.contains),
                            captionAngle: captionAngle(spokeCount: ifaceCount))
    }

    /// Midpoint of the widest gap between spokes — where a ring caption can sit
    /// without a bubble landing on top of it. Spokes are evenly spaced, so the
    /// widest gap is simply half a step past the last one.
    private static func captionAngle(spokeCount: Int) -> Double {
        guard spokeCount > 0 else { return .pi / 2 }
        let step = 2 * .pi / Double(spokeCount)
        return angleFor(index: spokeCount - 1, count: spokeCount) + step / 2
    }

    /// A synthetic topology at roughly the scale that broke the old layout —
    /// 341 destinations over three interfaces, hop counts from 1 to 27.
    ///
    /// Enabled with `-seedDemoData YES`, matching `DemoData`'s flag, and never
    /// compiled into Release. It exists because `-stackOffline YES` registers no
    /// interfaces, so `scripts/mac-screens.sh` had no way to photograph this
    /// screen with anything on it — which is how a view this broken stayed
    /// broken through several rounds of Mac-screen review.
    ///
    /// Deterministic (a fixed seed, no `Date()` beyond a single `now`), so two
    /// runs of the harness produce identical images and a diff between them
    /// means a real change.
    static var demo: NetworkGraph? {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "seedDemoData") else { return nil }
        let now = Date()
        // Hop counts chosen to populate every band, weighted the way a real
        // table is: most destinations a few hops out, a long thin tail.
        func members(_ count: Int, seed: UInt64, hops: [UInt8]) -> [Member] {
            var state = seed
            return (0..<count).map { i in
                // xorshift64 — a fixed-seed PRNG, so this is reproducible.
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let hex = String(format: "%016llx%016llx", state, state &* 0x9E37_79B9_7F4A_7C15)
                return Member(hashHex: String(hex.prefix(32)),
                              hops: hops[i % hops.count],
                              lastHeard: now.addingTimeInterval(-Double(i) * 37),
                              hasActiveLink: i % 97 == 0)
            }
        }
        return build(interfaces: [
            .init(name: "AutoInterface", type: .auto,
                  members: members(14, seed: 0x1234_5678, hops: [1, 1, 1, 2])),
            .init(name: "amsterdam.connect.reticulum.network", type: .tcp,
                  members: members(203, seed: 0xDEAD_BEEF, hops: [2, 3, 3, 4, 5, 6, 7, 9, 13, 27])),
            .init(name: "Simply Equipped Backbone", type: .backbone,
                  members: members(124, seed: 0xCAFE_F00D, hops: [1, 4, 5, 6, 8, 11, 19])),
        ])
        #else
        return nil
        #endif
    }

    private static func angleFor(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return (Double(index) / Double(count)) * 2 * .pi - .pi / 2
    }

    /// Same mapping as `polarPoint`, exposed for the ring captions so they can
    /// never disagree with node placement about where a ring is.
    static func captionPoint(angle: Double, radius: CGFloat) -> CGPoint {
        polarPoint(angle: angle, radius: radius)
    }

    private static func polarPoint(angle: Double, radius: CGFloat) -> CGPoint {
        // Keep the trig in `Double` throughout: mixing `cos(angle)` (Double)
        // with a `CGFloat` operand makes `cos`/`sin` overload resolution
        // ambiguous on newer toolchains. Convert the radius once.
        let r = Double(radius)
        return CGPoint(x: 0.5 + cos(angle) * r, y: 0.5 + sin(angle) * r)
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
                content
            }
            .overlay(Circle().stroke(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2))
            // `.shadow` on every bubble is an offscreen render pass each. Only
            // the selected one needs to lift off the canvas.
            .shadow(color: fillColor.opacity(isSelected ? 0.65 : 0),
                    radius: isSelected ? 9 : 0)

            if let caption {
                Text(caption)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.rnsTextSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: diameter + 56)
            }
        }
        .scaleEffect(isSelected ? 1.08 : 1.0)
    }

    /// Inside the bubble: a glyph for a node that *is* something, the count for
    /// a cluster that stands for many things. Putting the count inside is what
    /// lets clusters sit on a spoke without their captions colliding with the
    /// next bead out.
    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case .cluster(_, _, let count, _):
            Text("\(count)")
                .font(.system(size: diameter * 0.38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
        default:
            Image(systemName: glyph)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    /// Only nodes with a name worth reading carry an external caption. Clusters
    /// do not — their number is inside the bubble, and the ring guide already
    /// names the band.
    private var caption: String? {
        switch node.kind {
        case .me, .interface, .destination: return node.label
        case .cluster:                      return nil
        }
    }

    private var hasActiveLink: Bool {
        switch node.kind {
        case .destination(_, _, let active):  return active
        case .cluster(_, _, _, let active):   return active > 0
        default:                              return false
        }
    }

    private var diameter: CGFloat { node.kind.diameter }

    private var fillColor: Color {
        switch node.kind {
        case .me:                             return .rnsAccentBright
        case .interface(let type):            return type.color
        case .cluster(let type, _, _, _):     return type.color.opacity(0.85)
        case .destination(let type, _, _):    return type.color.opacity(0.78)
        }
    }

    private var glyph: String {
        switch node.kind {
        case .me:                          return "antenna.radiowaves.left.and.right"
        // Per-type glyph, so connection type is legible without relying on hue
        // alone (several of the type colors are near-identical blues/purples).
        case .interface(let type):         return type.glyph
        case .destination(let type, _, _): return type.glyph
        case .cluster(let type, _, _, _):  return type.glyph
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
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var trailing: some View {
        switch node.kind {
        case .destination(let type, let hops, let activeLink):
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
        case .cluster(let type, _, let count, let activeCount):
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if activeCount > 0 {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.rnsSuccess)
                    }
                    Text(type.label).font(.caption2.bold()).foregroundStyle(type.color)
                }
                Text("\(count) destination\(count == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .interface(let type):
            VStack(alignment: .trailing, spacing: 2) {
                Text(type.label).font(.caption2.bold()).foregroundStyle(type.color)
                Text("\(node.members.count) reachable")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .me:
            EmptyView()
        }
    }

    private var title: String {
        switch node.kind {
        case .me:                     return "This Node"
        case .interface:              return node.label
        case .cluster(_, let band, _, _): return band.label.capitalizedFirst
        case .destination:            return "Destination"
        }
    }

    private var subtitle: String {
        switch node.kind {
        case .me:                  return "centre of the mesh view"
        case .interface(let type): return type.label + " interface"
        case .cluster:             return "Tap the bubble to list them"
        case .destination:         return node.fullID
        }
    }
}

// MARK: - Cluster detail sheet

/// The destinations behind one cluster bubble.
///
/// This is the progressive-disclosure half of the aggregation: the canvas shows
/// the distribution, and this shows the individual hashes for whichever part of
/// it the user asked about — scoped, unlike the Paths tab, which lists all of
/// them at once.
private struct ClusterDetailSheet: View {
    let node: NetworkGraph.Node
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(node.members) { member in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.hashHex.truncatedHash)
                            .font(.caption.monospaced())
                        Text("last heard \(RNSDate.ago(member.lastHeard))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if member.hasActiveLink {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.rnsSuccess)
                            .accessibilityLabel("Active link")
                    }
                    Text("\(member.hops) hop\(member.hops == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { rnsCopyToPasteboard(member.hashHex) }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Double-tap to copy the full hash")
                .rnsRow()
            }
            .rnsContentListStyle()
            .navigationTitle(node.fullID)
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .rnsTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

private extension String {
    /// "direct" → "Direct", for a detail-bar title. `capitalized` would also
    /// re-case the rest ("2–3 Hops").
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
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

    /// A distinct SF Symbol per connection type, so type is distinguishable in
    /// the graph without relying on hue alone (several of the type colors are
    /// near-identical blues/purples/greens). Used on node bubbles and in the
    /// legend; node *kind* stays encoded by bubble size and ring position.
    var glyph: String {
        switch self {
        case .tcp:      return "network"
        case .udp:      return "dot.radiowaves.left.and.right"
        case .auto:     return "wifi"
        case .backbone: return "point.3.filled.connected.trianglepath.dotted"
        case .local:    return "house.fill"
        case .lora:     return "antenna.radiowaves.left.and.right"
        case .i2p:      return "lock.shield"
        case .serial:   return "cable.connector"
        case .other:    return "questionmark.circle"
        }
    }
}
