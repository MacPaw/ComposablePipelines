//
//  GuardrailRule.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Policy rules understood by the composed guardrail classifier.
///
/// Raw values match the string encoding used in `ModelArguments`;
/// `classIndex` maps each rule to its column in the classifier's probability output.
public enum GuardrailRule: String, Codable, Sendable, Hashable, CaseIterable {
    case illegal
    case harmful
    case sexual
    case malicious
    case geopolitics
    /// Alias for ``geopolitics``.
    case politics
    /// Personally-identifiable information detection.
    case pii

    /// Column index in the classifier's probability array for this rule.
    public var classIndex: Int {
        switch self {
        case .illegal:              return 0
        case .harmful:              return 1
        case .sexual:               return 2
        case .malicious:            return 3
        case .geopolitics, .politics: return 4
        case .pii:                  return 5
        }
    }
}
