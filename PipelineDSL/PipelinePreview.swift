//
//  PipelinePreview.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

/// Generates `static var dslPreview: String` from the pipeline's `body` source text at compile time.
@attached(member, names: named(dslPreview))
public macro PipelinePreview() = #externalMacro(module: "PipelinePreviewMacro", type: "PipelinePreviewMacro")
