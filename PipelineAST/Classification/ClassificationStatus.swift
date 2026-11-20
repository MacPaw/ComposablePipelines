//
//  ClassificationStatus.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

/// Whether a classification step actually ran.
///
/// Carried on every classification result so a host can never read "nobody looked" as "nothing found":
/// an empty span list from an evaluated detector is a clean text; from an unavailable one it means nothing.
public enum ClassificationStatus: String, Codable, Hashable, Sendable {
    /// A backend scored the text. The payload is the model's answer, which may be legitimately empty.
    case evaluated
    /// No backend could serve the task (or its pinned checkpoint). The payload is empty and means nothing.
    case unavailable
}
