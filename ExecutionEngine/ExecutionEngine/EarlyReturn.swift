//
//  EarlyReturn.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
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
