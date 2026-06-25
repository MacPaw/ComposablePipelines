//
//  PipelineExecutionGraph+SurfaceTaskCount.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

extension PipelineExecutionGraph {
    /// Number of surface `.task` nodes in branch-major walk space.
    public func surfaceTaskCount() -> Int {
        switch self {
        case .empty:
            return 0
        case .task:
            return 1
        case .returnWith(let inner):
            return inner.surfaceTaskCount()
        case .sequential(let steps):
            return steps.reduce(0) { $0 + $1.surfaceTaskCount() }
        case .parallel(let branches):
            return branches.reduce(0) { $0 + $1.surfaceTaskCount() }
        }
    }
}
