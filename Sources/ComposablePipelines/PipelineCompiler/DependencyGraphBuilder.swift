import Foundation
import PipelineAST

/// Phase 1: Walks a `PipelineGraph` AST and produces a flat `DependencyGraph` with explicit edges.
///
/// Implicitly `~Copyable` (stores `DependencyGraph: ~Copyable`).
/// `build(from:)` is `consuming` — the builder is destroyed after producing the graph,
/// enforcing single-use semantics and zero-copy transfer of the node/edge arrays.
struct DependencyGraphBuilder: ~Copyable {
    private var graph = DependencyGraph()
    private let logger: PipelineLog

    init(logger: PipelineLog = .none) {
        self.logger = logger.subLogger("dependency-graph-builder")
    }

    consuming func build(from ast: PipelineGraph) -> DependencyGraph {
        logger.log(.verbose, "building dependency graph")
        graph = DependencyGraph()
        flattenSequence(ast)
        logger.log(.verbose, "flattened \(graph.nodes.count) nodes")
        buildSlotOrderingEdges()
        buildGateSuccessorEdges()
        buildConservativeOrderingEdges()
        graph.finalize()
        logger.log(.verbose, "dependency graph built: \(graph.nodes.count) nodes, \(graph.edges.count) edges, \(graph.gateIndices.count) gates")
        return graph
    }

    // MARK: - Flatten

    @discardableResult
    private mutating func flattenSequence(_ ast: PipelineGraph) -> [UUID] {
        switch ast {
        case .empty:
            return []

        case let .sequence(items):
            var allIDs: [UUID] = []
            for item in items {
                allIDs.append(contentsOf: flattenSequence(item))
            }
            return allIDs

        case let .group(sequential: false, gate: false, content):
            return flattenSequence(content)

        default:
            let isGate: Bool
            if case let .group(_, gate, _) = ast { isGate = gate } else { isGate = false }
            let id = addNode(for: ast, isGate: isGate)
            return [id]
        }
    }

    // MARK: - Node creation

    @discardableResult
    private mutating func addNode(for ast: PipelineGraph, isGate: Bool = false) -> UUID {
        let id = UUID()
        let access = SlotAccess.collect(from: ast)
        let index = graph.nodes.count
        let node = DependencyGraph.Node(id: id, astFragment: ast, slotAccess: access, isGate: isGate)
        graph.nodes.append(node)
        if isGate { graph.gateIndices.append(index) }
        let gateTag = isGate ? " [gate]" : ""
        logger.log(.verbose, "node \(id.shortID) reads=\(access.reads.map(\.shortID)) writes=\(access.writes.map(\.shortID))\(gateTag)")
        return id
    }

    // MARK: - Slot ordering edges (RAW, WAW, WAR)

    /// Adds ordering edges for slot hazards: read-after-write, write-after-write,
    /// and write-after-read. Concurrent reads of the same slot are allowed.
    private mutating func buildSlotOrderingEdges() {
        var lastWriter: [UUID: Int] = [:]
        var lastReader: [UUID: Int] = [:]

        for (i, node) in graph.nodes.enumerated() {
            for slotID in node.slotAccess.reads {
                // RAW: reader depends on last writer
                if let w = lastWriter[slotID] {
                    addSlotEdge(from: w, to: i, slotID: slotID)
                }
                lastReader[slotID] = i
            }
            for slotID in node.slotAccess.writes {
                // WAW: writer depends on last writer
                if let w = lastWriter[slotID] {
                    addSlotEdge(from: w, to: i, slotID: slotID)
                }
                // WAR: writer depends on last reader
                if let r = lastReader[slotID] {
                    addSlotEdge(from: r, to: i, slotID: slotID)
                }
                lastWriter[slotID] = i
            }
        }
    }

    private mutating func addSlotEdge(from: Int, to: Int, slotID: UUID) {
        // A single dep-graph node may both read and write the same slot — e.g.
        // when `group(sequential: true)` collapses a subtree whose internal
        // ordering already takes care of the read-then-write hazard. The node
        // can't be its own predecessor; skipping prevents an unbreakable cycle
        // that would otherwise drop it from the topological sort.
        guard from != to else { return }
        let edge = DependencyGraph.Edge(
            from: graph.nodes[from].id,
            to: graph.nodes[to].id
        )
        let inserted = graph.edges.insert(edge).inserted
        if inserted {
            logger.log(.verbose, "slot-order edge: \(graph.nodes[from].id.shortID) → \(graph.nodes[to].id.shortID) via slot \(slotID.shortID)")
        }
    }

    /// Ensures the first pipeline step after a **gate** node waits for that gate (condition reads,
    /// guardrail, etc.). Slot-only ordering can miss this when the next step does not re-read the
    /// same slot (e.g. first `else` arm writes `category` while the gate only read `severity`).
    private mutating func buildGateSuccessorEdges() {
        for (i, node) in graph.nodes.enumerated() where node.isGate {
            guard i + 1 < graph.nodes.count else { continue }
            let edge = DependencyGraph.Edge(
                from: graph.nodes[i].id,
                to: graph.nodes[i + 1].id
            )
            if graph.edges.insert(edge).inserted {
                logger.log(.verbose, "gate-successor edge: \(graph.nodes[i].id.shortID) → \(graph.nodes[i + 1].id.shortID)")
            }
        }
    }

    // MARK: - Conservative ordering for opaque nodes

    private mutating func buildConservativeOrderingEdges() {
        guard graph.nodes.count > 1 else { return }
        for i in 1..<graph.nodes.count {
            let current = graph.nodes[i]
            let previous = graph.nodes[i - 1]

            let currentHasAccess = !current.slotAccess.isEmpty
            let previousHasAccess = !previous.slotAccess.isEmpty

            if currentHasAccess && previousHasAccess {
                continue
            }

            let edge = DependencyGraph.Edge(from: previous.id, to: current.id)
            if graph.edges.insert(edge).inserted {
                logger.log(.verbose, "conservative edge: \(previous.id.shortID) → \(current.id.shortID)")
            }
        }
    }
}
