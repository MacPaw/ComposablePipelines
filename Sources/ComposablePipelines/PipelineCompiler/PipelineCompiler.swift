import Foundation
import PipelineAST

public struct PipelineCompiler {

    public struct Optimizations: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let parallelize = Optimizations(rawValue: 1 << 0)

        public static let `default`: Optimizations = [.parallelize]
        public static let none: Optimizations = []
    }

    let logger: PipelineLog
    public let optimizations: Optimizations

    public init(optimizations: Optimizations = .default, logger: PipelineLog = .none) {
        self.optimizations = optimizations
        self.logger = logger.subLogger("pipeline-compiler")
    }

    public func compile(_ ast: PipelineGraph) -> PipelineExecutionGraph {
        logger.log(.verbose, "compile started (optimizations: \(optimizations))")
        
        let timer = ElapsedTimer()

        let dependencyGraph = DependencyGraphBuilder(logger: logger).build(from: ast)

        let emitter = ExecutionGraphEmitter(optimizations: optimizations, logger: logger)
        let result = emitter.emit(from: dependencyGraph)

        logger.log(.verbose, "compilation time - \(timer.nanoseconds().prettyDuration)")

        return result
    }
}
