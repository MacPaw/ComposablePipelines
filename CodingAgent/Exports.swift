//
//  Exports.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

// The agent loop, its stop policies, the progress probe, `finish` and conversation history moved
// into the ComposablePipelines core; importing CodingAgent alone keeps reaching them.
@_exported import ComposablePipelines
