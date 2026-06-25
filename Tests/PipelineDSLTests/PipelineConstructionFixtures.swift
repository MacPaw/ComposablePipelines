//
//  PipelineConstructionFixtures.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineDSL

// MARK: - Nested pipeline shape

enum NestedPipelineFixture {
    struct Prefix: LeafPipeline {
        typealias Output = String
    }
    struct InnerA: LeafPipeline {
        typealias Output = String
    }
    struct InnerB: LeafPipeline {
        typealias Output = String
    }
    struct Suffix: LeafPipeline {
        typealias Output = String
    }

    struct InnerPipeline: Pipeline {
        typealias Output = String

        var body: some Pipeline {
            InnerA()
            InnerB()
        }
    }

    struct OuterPipeline: Pipeline {
        typealias Output = String

        @PipelineBuilder var body: some Pipeline {
            Prefix()
            InnerPipeline()
            Suffix()
        }
    }
}

// MARK: - Linear A -> B -> C

enum LinearSequenceFixture {
    struct A: LeafPipeline {
        typealias Output = String
    }
    struct B: LeafPipeline {
        typealias Output = String
    }
    struct C: LeafPipeline {
        typealias Output = String
    }

    struct Linear: Pipeline {
        typealias Output = String

        var body: some Pipeline {
            A()
            B()
            C()
        }
    }
}

// MARK: - ForEach

enum ForEachFixture {
    struct Host: Pipeline {
        typealias Output = String

        let indices: [Int]

        var body: some Pipeline {
            ForEach(in: { indices }) { _ in
                LinearSequenceFixture.A()
            }
        }
    }
}

// MARK: - Empty builder body

enum EmptyGraphFixture {
    struct EmptyBody: Pipeline {
        typealias Output = Never

        @PipelineBuilder var body: some Pipeline {}
    }
}
