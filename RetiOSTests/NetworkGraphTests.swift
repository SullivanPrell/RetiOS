import XCTest
import SwiftUI
@testable import RetiOS

/// Covers the aggregation that replaced the node-per-destination visualizer.
///
/// The bug being locked down is a *scaling* one, so these tests are about a
/// bound, not about a picture. With a real path table of 341 entries over three
/// interfaces the old layout fanned ~113 bubbles across a 110° sector at a
/// ~177 pt radius — 3.0 pt of arc per node against a 22 pt bubble and a ~78 pt
/// label, a 7× overlap that rendered as two solid crescent-shaped smears. The
/// only fix that survives contact with a growing mesh is one where node count
/// stops tracking path-table size, and that is exactly what is asserted here.
final class NetworkGraphTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// `count` synthetic destinations spread over the given hop counts.
    private func members(_ count: Int, hops: [UInt8], active: Int = 0) -> [NetworkGraph.Member] {
        (0..<count).map { i in
            NetworkGraph.Member(hashHex: String(format: "%032x", i + 1),
                                hops: hops[i % hops.count],
                                lastHeard: now,
                                hasActiveLink: i < active)
        }
    }

    private func iface(_ name: String,
                       _ type: ConnectionType,
                       _ members: [NetworkGraph.Member]) -> NetworkGraph.InterfaceInput {
        NetworkGraph.InterfaceInput(name: name, type: type, members: members)
    }

    private func destinationCount(_ graph: NetworkGraph) -> Int {
        graph.nodes.reduce(0) { total, node in
            switch node.kind {
            case .cluster(_, _, let count, _): return total + count
            case .destination:                 return total + 1
            default:                           return total
            }
        }
    }

    // MARK: - The bound

    /// The headline guarantee: node count is a function of interfaces and hop
    /// bands, never of how much of the mesh is known.
    func testNodeCountDoesNotGrowWithPathTableSize() {
        let hops: [UInt8] = [1, 2, 3, 5, 9, 27]
        let small = NetworkGraph.build(interfaces: [iface("tcp", .tcp, members(30, hops: hops))])
        let huge  = NetworkGraph.build(interfaces: [iface("tcp", .tcp, members(5000, hops: hops))])

        XCTAssertEqual(small.nodes.count, huge.nodes.count,
                       "30 and 5000 destinations must draw the same number of bubbles")
        XCTAssertEqual(destinationCount(small), 30)
        XCTAssertEqual(destinationCount(huge), 5000,
                       "aggregating must not lose destinations — every one is still accounted for")
    }

    /// The scale the user actually reported: 341 paths over three interfaces.
    /// A phone canvas holds roughly 60 nodes at legible spacing on a full
    /// circle, so this is the number that has to stay small.
    func testReportedScaleStaysWellUnderTheLegibilityCeiling() {
        let graph = NetworkGraph.build(interfaces: [
            iface("AutoInterface", .auto, members(14, hops: [1, 2])),
            iface("amsterdam", .tcp, members(203, hops: [2, 3, 5, 7, 13, 27])),
            iface("backbone", .backbone, members(124, hops: [1, 4, 8, 19])),
        ])

        XCTAssertEqual(destinationCount(graph), 341)
        XCTAssertLessThan(graph.nodes.count, 24,
                          "341 destinations must not produce anything near 341 bubbles")
        // 1 "me" + 3 interfaces + at most one bead per (interface, band).
        let ceiling = 1 + 3 * (1 + HopBand.allCases.count)
        XCTAssertLessThanOrEqual(graph.nodes.count, ceiling)
    }

    // MARK: - Aggregation behaviour

    /// Below the threshold a band shows the destinations themselves — hiding
    /// two hashes behind a "2" the user has to tap would be worse than useless.
    func testSmallBandsRenderIndividualDestinations() {
        let graph = NetworkGraph.build(interfaces: [iface("tcp", .tcp, members(2, hops: [1]))])

        let dests = graph.nodes.filter { if case .destination = $0.kind { return true }; return false }
        let clusters = graph.nodes.filter { if case .cluster = $0.kind { return true }; return false }
        XCTAssertEqual(dests.count, 2)
        XCTAssertTrue(clusters.isEmpty)
    }

    func testLargeBandsCollapseIntoOneCluster() {
        let graph = NetworkGraph.build(interfaces: [iface("tcp", .tcp, members(200, hops: [1]))])

        let clusters = graph.nodes.filter { if case .cluster = $0.kind { return true }; return false }
        XCTAssertEqual(clusters.count, 1, "one band, one bead")
        XCTAssertEqual(clusters.first?.members.count, 200,
                       "the cluster must carry its members so the detail sheet can list them")
        XCTAssertEqual(clusters.first?.label, "200", "the count is the bubble's label")
    }

    /// An active link anywhere inside a cluster has to survive aggregation —
    /// it is the one piece of live state the graph shows.
    func testActiveLinkCountSurvivesAggregation() {
        let graph = NetworkGraph.build(interfaces: [
            iface("tcp", .tcp, members(50, hops: [1], active: 3))
        ])

        let cluster = graph.nodes.first { if case .cluster = $0.kind { return true }; return false }
        guard case .cluster(_, _, let count, let activeCount)? = cluster?.kind else {
            return XCTFail("expected a cluster")
        }
        XCTAssertEqual(count, 50)
        XCTAssertEqual(activeCount, 3)
    }

    // MARK: - Bands

    func testHopBandBoundaries() {
        XCTAssertEqual(HopBand(hops: 0), .direct)
        XCTAssertEqual(HopBand(hops: 1), .direct)
        XCTAssertEqual(HopBand(hops: 2), .near)
        XCTAssertEqual(HopBand(hops: 3), .near)
        XCTAssertEqual(HopBand(hops: 4), .mid)
        XCTAssertEqual(HopBand(hops: 7), .mid)
        XCTAssertEqual(HopBand(hops: 8), .far)
        XCTAssertEqual(HopBand(hops: 255), .far)
    }

    /// Every band gets its own radius, increasing outward. The old code packed
    /// all levels into [0.35, 0.47] — the outer quarter of the canvas — which is
    /// why the middle of the graph was empty while its rim was a smear.
    func testBandRadiiAreDistinctAndIncreasing() {
        let radii = HopBand.allCases.map(\.radius)
        XCTAssertEqual(radii, radii.sorted())
        XCTAssertEqual(Set(radii).count, radii.count)
        XCTAssertGreaterThan(radii.last! - radii.first!, 0.2,
                             "bands must use the canvas, not huddle in one ring")
        // 0.5 reaches the edge exactly. A cluster bubble is up to 48 pt across,
        // so a centre placed at 0.5 loses its outer half — and `polarPoint`
        // deliberately applies no clamp, because the old code's clamp collapsed
        // distinct positions onto the same edge point. The radii themselves have
        // to leave room for the bubble.
        XCTAssertLessThanOrEqual(radii.last!, 0.42,
                                 "outermost band must leave room for a 48 pt bubble")
    }

    /// Only the bands that contain something get a ring guide — an empty ring
    /// labelled "8+ hops" claims knowledge the node does not have.
    func testOnlyOccupiedBandsGetRingGuides() {
        let graph = NetworkGraph.build(interfaces: [
            iface("tcp", .tcp, members(10, hops: [1, 5]))   // .direct and .mid only
        ])
        XCTAssertEqual(graph.occupiedBands, [.direct, .mid])
    }

    // MARK: - Structure

    func testEmptyTransportYieldsOnlyThisNode() {
        let graph = NetworkGraph.build(interfaces: [])
        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertTrue(graph.edges.isEmpty)
    }

    /// An interface with no known paths is still worth drawing — "this radio is
    /// up and has found nobody" is real information.
    func testInterfaceWithNoPathsStillAppears() {
        let graph = NetworkGraph.build(interfaces: [iface("lonely", .lora, [])])
        XCTAssertEqual(graph.nodes.count, 2)          // me + the interface
        XCTAssertEqual(graph.edges.count, 1)
    }

    /// Every edge must resolve at both ends, or `edgesLayer` silently drops the
    /// line and the spoke renders as floating beads.
    func testEveryEdgeResolvesToRealNodes() {
        let graph = NetworkGraph.build(interfaces: [
            iface("AutoInterface", .auto, members(14, hops: [1, 2])),
            iface("amsterdam", .tcp, members(203, hops: [2, 3, 5, 7, 13, 27])),
            iface("backbone", .backbone, members(124, hops: [1, 4, 8, 19])),
        ])
        for edge in graph.edges {
            XCTAssertNotNil(graph.node(edge.from), "dangling edge source \(edge.from)")
            XCTAssertNotNil(graph.node(edge.to), "dangling edge target \(edge.to)")
        }
    }

    /// Node ids must be unique — `indexByID` dedupes on collision, so a
    /// duplicate would make `node(_:)` return the wrong bubble for an edge.
    func testNodeIDsAreUnique() {
        let graph = NetworkGraph.build(interfaces: [
            iface("a", .tcp, members(100, hops: [1, 4, 9])),
            iface("b", .tcp, members(100, hops: [1, 4, 9])),
        ])
        XCTAssertEqual(Set(graph.nodes.map(\.id)).count, graph.nodes.count)
    }

    /// Every node lands inside the canvas. The old layout clamped positions to
    /// 0.05...0.95 after the fact, which collapsed distinct polar positions onto
    /// the same edge point; the band radii are chosen so no clamp is needed.
    func testAllNodesLandInsideTheCanvas() {
        let graph = NetworkGraph.build(interfaces: (0..<7).map {
            iface("iface\($0)", .tcp, members(60, hops: [1, 3, 6, 12]))
        })
        for node in graph.nodes {
            XCTAssertTrue((0.0...1.0).contains(node.normPosition.x), "\(node.id) x=\(node.normPosition.x)")
            XCTAssertTrue((0.0...1.0).contains(node.normPosition.y), "\(node.id) y=\(node.normPosition.y)")
        }
    }

    /// Ring captions must not land on a spoke. `angleFor(index: 0, count:)` is
    /// `-.pi/2` for every count, so interface 0's spoke always runs straight up
    /// — a caption pinned to the top of each ring was drawn inside one of that
    /// spoke's bubbles and painted over.
    func testCaptionAngleAvoidsEverySpoke() {
        for count in 1...8 {
            let graph = NetworkGraph.build(interfaces: (0..<count).map {
                iface("iface\($0)", .tcp, members(20, hops: [1, 5]))
            })
            let step = 2 * Double.pi / Double(count)
            for i in 0..<count {
                let spoke = (Double(i) / Double(count)) * 2 * .pi - .pi / 2
                var delta = abs(graph.captionAngle - spoke)
                    .truncatingRemainder(dividingBy: 2 * .pi)
                if delta > .pi { delta = 2 * .pi - delta }
                XCTAssertGreaterThan(delta, step / 4,
                                     "caption sits on spoke \(i) of \(count)")
            }
        }
    }

    /// Hit targets meet the HIG 44 pt minimum even though every bubble is drawn
    /// smaller than that.
    func testEveryHitTargetMeetsTheMinimum() {
        let graph = NetworkGraph.build(interfaces: [
            iface("tcp", .tcp, members(300, hops: [1, 2, 5, 11])),
            iface("solo", .lora, members(1, hops: [1])),
        ])
        for node in graph.nodes {
            XCTAssertGreaterThanOrEqual(node.kind.hitDiameter, 44, "\(node.id)")
        }
    }

    /// Cluster bubbles grow with membership but stay on the canvas — a linear
    /// map would make a 300-member cluster twelve times a 25-member one.
    func testClusterDiameterIsBoundedAndMonotonic() {
        let small = NetworkGraph.Node.Kind.cluster(.tcp, band: .direct, count: 4, activeCount: 0)
        let big   = NetworkGraph.Node.Kind.cluster(.tcp, band: .direct, count: 300, activeCount: 0)
        let huge  = NetworkGraph.Node.Kind.cluster(.tcp, band: .direct, count: 100_000, activeCount: 0)

        XCTAssertLessThan(small.diameter, big.diameter)
        XCTAssertLessThanOrEqual(huge.diameter, 48, "a cluster must never run off the canvas")
    }
}
