import Foundation
import PipelineAST

/// Typed slot in remote execution context.
///
/// Leaf steps for runner I/O use the projected binding:
/// ```swift
/// @State var memory: String = ""
/// var body: some Pipeline {
///     $memory.set("hello")
///     $memory.get
/// }
/// ```


@propertyWrapper
public struct State<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    public let id: UUID
    public let debugLabel: String?
    public let initialValue: Value

    public init(
        wrappedValue: Value,
        _ debugLabel: String? = nil
    ) {
        self.id = UUID()
        self.initialValue = wrappedValue
        self.debugLabel = debugLabel
    }

    public var valueTypeName: String {
        String(describing: Value.self)
    }

    /// JSON-encoded ``initialValue`` baked into emitted `executionStateGet` leaves so the
    /// engine can serve the slot's default value without an explicit `initialSlots` seeding.
    /// Falls back to `"null"` if encoding throws (defensive — `Value: Codable` should always encode).
    public var initialValueJSON: String {
        let data = (try? JSONEncoder().encode(initialValue)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public var wrappedValue: Value {
        guardNotInsideClientTask()
        if ExecutionContext.isEmittingPipelineGraph {
            GraphEmissionContext.current?.recordRead(
                slotID: id,
                valueTypeName: valueTypeName,
                debugLabel: debugLabel,
                defaultJSON: initialValueJSON
            )
            return valueAsOfCurrentEpoch()
        }
        return executionValueFromBindings
    }
    
    public var projectedValue: Binding<Value> {
        Binding(state: self)
    }

    private var executionValueFromBindings: Value {
        guard let context = ExecutionContext.current,
              let data = context.bindings[id] else { return initialValue }
        return (try? JSONDecoder().decode(Value.self, from: data)) ?? initialValue
    }

    private func valueAsOfCurrentEpoch() -> Value {
        guard let context = ExecutionContext.current else { return initialValue }
        let epoch = ExecutionContext.executionEpoch
        if let data = context.asOfData(slotID: id, executionEpoch: epoch),
           let v = try? JSONDecoder().decode(Value.self, from: data) {
            return v
        }
        return initialValue
    }

    func guardNotInsideClientTask() {
        guard ExecutionContext.isExecutingClientTask else { return }
        fatalError("State value are meant to be accessed in a pipeline by executor, not directly. Use ClientTask input to pass state into task.")
    }
}

/// Stable handle for a slot (`$foo` when using ``State`` as a property wrapper).
public struct Binding<Value: Hashable & Sendable & Codable>: Hashable, Sendable {
    public let state: State<Value>

    public init(state: State<Value>) {
        self.state = state
    }

    public var id: UUID { state.id }
    public var defaultValue: Value { state.initialValue }
    public var valueTypeName: String { state.valueTypeName }

    /// - Parameter writeKind: ``StateWriteKind/commit`` (default) participates in reactive recompilation;
    ///   ``StateWriteKind/draft`` updates the runner slot for observers but does not invoke the engine `graphProvider`.
    public func set<Source: Pipeline>(
        _ pipeline: Source,
        writeKind: StateWriteKind = .commit
    ) -> SetValue<Source> where Source.Output == Value {
        state.guardNotInsideClientTask()
        let ctx = GraphEmissionContext.current
        let snapshot = ctx?.readCount ?? 0
        let reads = ctx?.drainReadsSince(snapshot) ?? []
        return SetValue(state: state, pipeline: pipeline, capturedReads: reads, writeKind: writeKind)
    }

    public func set<Source: Pipeline>(
        writeKind: StateWriteKind = .commit,
        @PipelineBuilder _ pipeline: () -> Source
    ) -> SetValue<Source> where Source.Output == Value {
        state.guardNotInsideClientTask()
        let ctx = GraphEmissionContext.current
        let snapshot = ctx?.readCount ?? 0
        let source = pipeline()
        let reads = ctx?.drainReadsSince(snapshot) ?? []
        return SetValue(state: state, pipeline: source, capturedReads: reads, writeKind: writeKind)
    }

    public func set(
        _ value: Value,
        writeKind: StateWriteKind = .commit
    ) -> SetValue<Just<Value>> where Value: Encodable {
        state.guardNotInsideClientTask()
        let ctx = GraphEmissionContext.current
        let snapshot = ctx?.readCount ?? 0
        let reads = ctx?.drainReadsSince(snapshot) ?? []
        return SetValue(state: state, pipeline: Just(value: value), capturedReads: reads, writeKind: writeKind)
    }

    /// Graph-level slot read (lowers to `executionStateGet`).
    public func get() -> GetValue {
        state.guardNotInsideClientTask()
        return GetValue(state: state)
    }

    internal var _get: GetValue {
        state.guardNotInsideClientTask()
        return GetValue(state: state)
    }

    public struct SetValue<Source: Pipeline>: LeafPipeline where Source.Output == Value {
        public typealias Output = Value

        public let state: State<Value>
        public let pipeline: Source
        let capturedReads: [PipelineGraph]
        let writeKind: StateWriteKind

        public var pipelineGraph: PipelineGraph {
            // During re-lowering (executionEpoch > 0), if this slot was already committed
            // in the current pipeline run, lower to a read-only get. This prevents
            // non-deterministic model outputs from triggering infinite re-evaluation cycles:
            // each pass produces a new value → `previousValue != value` → re-evaluation forever.
            // Only applies to commit writes; draft writes bypass this check.
            if writeKind == .commit,
               ExecutionContext.isEmittingPipelineGraph,
               let context = ExecutionContext.current {
                let epoch = ExecutionContext.executionEpoch
                if epoch > 0 {
                    let alreadyCommitted = context.$slotHistory.read { dict in
                        dict[state.id]?.contains(where: { $0.epoch <= epoch }) == true
                    }
                    if alreadyCommitted {
                        return .leaf(.executionStateGet(
                            id: state.id,
                            valueTypeName: String(describing: Value.self),
                            debugLabel: state.debugLabel,
                            defaultJSON: state.initialValueJSON
                        ))
                    }
                }
            }
            let leaf = PipelineGraph.leaf(
                .executionStateSet(
                    id: state.id,
                    valueTypeName: String(describing: Value.self),
                    value: pipeline.pipelineGraph,
                    debugLabel: state.debugLabel,
                    writeKind: writeKind
                )
            )
            guard !capturedReads.isEmpty else { return leaf }
            return .group(
                sequential: true, gate: false,
                .sequence(capturedReads + [leaf])
            )
        }
    }

    public struct GetValue: LeafPipeline {
        public typealias Output = Value

        public let state: State<Value>

        public var pipelineGraph: PipelineGraph {
            .leaf(
                .executionStateGet(
                    id: state.id,
                    valueTypeName: state.valueTypeName,
                    debugLabel: state.debugLabel,
                    defaultJSON: state.initialValueJSON
                )
            )
        }
    }

    public var debugDescription: String {
        state.debugLabel ?? state.id.uuidString
    }
}

extension Binding: PipelineConvertible {
    public typealias Output = Value
    public var representedAsPipeline: any Pipeline {
        self._get
    }
}

@available(*, deprecated, renamed: "State")
public typealias ExecutionState = State

@available(*, deprecated, renamed: "Binding")
public typealias ExecutionBinding = Binding
