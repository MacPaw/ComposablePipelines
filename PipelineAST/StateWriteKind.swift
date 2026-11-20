//
//  StateWriteKind.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Whether a slot write participates in reactive pipeline re-emission.
///
/// - ``commit``: advances committed epoch; triggers ``PipelineWalker`` commit flush, then
///   optional cursor-only graph replacement after state is delivered.
///   after the flush (same as historical behavior).
/// - ``draft``: updates the live slot value and emits ``ExecutionEvent/stateUpdated``, but does
///   **not** advance committed epoch or schedule graph recompilation — for incremental previews
///   (e.g. streaming) until a commit arrives.
public enum StateWriteKind: String, Codable, Sendable, Hashable {
    case draft
    case commit
}
