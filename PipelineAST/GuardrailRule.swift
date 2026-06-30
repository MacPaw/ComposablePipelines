//
//  GuardrailRule.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Policy rules understood by the composed guardrail classifier.
public enum GuardrailRule: String, Codable, Sendable, Hashable {
    case politics
    case pii
}
