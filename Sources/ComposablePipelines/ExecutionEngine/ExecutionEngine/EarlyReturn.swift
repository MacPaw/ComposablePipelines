//
//  EarlyReturn.swift
//  elix-toolchain
//
//  Created by Oleksandr Frankiv on 20.04.2026.
//

import Foundation

/// Thrown internally by the graph walker when a `.returnWith` node is evaluated.
///
/// This is a control-flow mechanism, not a real error.
/// It propagates up the recursive `walk` call stack and is caught at the top
/// of `PipelineWalker.run(...)`, where its `value` is returned as the final result.
struct EarlyReturn: Error {
    let value: ExecutionValue
}
