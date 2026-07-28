//
//  SugarConstructionTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
@_spi(Internals) @testable import PipelineDSL

/// Every new Tier-1 spelling must lower to the *same* graph as its verbose form.
final class SugarConstructionTests: XCTestCase {

    // MARK: - Model: unlabeled prompt / generating: / InstructionsBuilder

    private struct Sentiment: ModelOutput {
        let label: String
    }

    func testModel_unlabeledPrompt_equalsSystemPromptModifier() {
        let sugar = Model<String>("Classify sentiment.").input("hi").loweredGraph()
        let verbose = Model<String>().systemPrompt("Classify sentiment.").input("hi").loweredGraph()
        XCTAssertEqual(sugar, verbose, PipelineGraphTestHelpers.prettyPrint(sugar))
    }

    func testModel_generating_pinsOutputTypeName() {
        let graph = Model("Review it.", generating: Sentiment.self).input("hi").loweredGraph()
        guard case let .leaf(.model(config, _)) = graph else {
            return XCTFail("expected model leaf, got:\n\(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertEqual(config.outputTypeName, "Sentiment")
    }

    func testModel_instructionsBuilder_joinsLinesWithNewlines() {
        let sugar = Model<String> {
            "Write a research brief."
            "Cite every fact you use."
        }
        .input("notes")
        .loweredGraph()

        let verbose = Model<String>()
            .systemPrompt("Write a research brief.\nCite every fact you use.")
            .input("notes")
            .loweredGraph()

        XCTAssertEqual(sugar, verbose, PipelineGraphTestHelpers.prettyPrint(sugar))
    }

    func testInstructionsBuilder_dropsEmptyConditionalLines() {
        let includeExtra = false
        let prompt = Model<String> {
            "Base line."
            if includeExtra { "Extra line." }
        }
        .input("x")
        .loweredGraph()

        let expected = Model<String>().systemPrompt("Base line.").input("x").loweredGraph()
        XCTAssertEqual(prompt, expected)
    }

    // MARK: - Bare $binding as a step

    private struct BareBindingFixture: Pipeline {
        typealias Output = String
        @State var reply = "hi"

        var body: some Pipeline {
            $reply.set("hello")
            $reply           // bare binding == $reply.get()
        }
    }

    private struct ExplicitGetFixture: Pipeline {
        typealias Output = String
        @State var reply = "hi"

        var body: some Pipeline {
            $reply.set("hello")
            $reply.get()
        }
    }

    func testBareBinding_equalsExplicitGet() {
        // Same slot id across the two fixtures isn't guaranteed, so compare shapes structurally
        // by pretty-print rather than raw UUID equality.
        let bare = BareBindingFixture().loweredGraph()
        let explicit = ExplicitGetFixture().loweredGraph()
        XCTAssertEqual(
            PipelineGraphTestHelpers.shape(of: bare),
            PipelineGraphTestHelpers.shape(of: explicit)
        )
    }

    // MARK: - While autoclosure

    private struct WhileAutoclosure: Pipeline {
        typealias Output = Bool
        @State var done = false

        var body: some Pipeline {
            While(!done) {
                $done.set(true)
            }
            $done
        }
    }

    private struct WhileClosure: Pipeline {
        typealias Output = Bool
        @State var done = false

        var body: some Pipeline {
            While(condition: { !done }) {
                $done.set(true)
            }
            $done
        }
    }

    func testWhile_autoclosure_equalsClosureForm() {
        let auto = WhileAutoclosure().loweredGraph()
        let closure = WhileClosure().loweredGraph()
        XCTAssertEqual(
            PipelineGraphTestHelpers.shape(of: auto),
            PipelineGraphTestHelpers.shape(of: closure)
        )
    }

    // MARK: - ForEach unlabeled

    func testForEach_unlabeled_equalsInLabel() {
        let unlabeled = ForEach([1, 2, 3]) { Just(value: $0) }.loweredGraph()
        let labeled = ForEach(in: [1, 2, 3]) { Just(value: $0) }.loweredGraph()
        XCTAssertEqual(unlabeled, labeled, PipelineGraphTestHelpers.prettyPrint(unlabeled))
    }

    // MARK: - Group sugar

    func testConcurrent_equalsGroupSequentialFalse() {
        let sugar = Concurrent { Just(value: 1); Just(value: 2) }.loweredGraph()
        let verbose = Group(sequential: false) { Just(value: 1); Just(value: 2) }.loweredGraph()
        XCTAssertEqual(sugar, verbose, PipelineGraphTestHelpers.prettyPrint(sugar))
    }

    func testBarrier_equalsGroupGateTrue() {
        let sugar = Barrier { Just(value: 1) }.loweredGraph()
        let verbose = Group(gate: true) { Just(value: 1) }.loweredGraph()
        XCTAssertEqual(sugar, verbose, PipelineGraphTestHelpers.prettyPrint(sugar))
    }

    func testGroupGated_equalsGroupGateTrue() {
        let sugar = Group { Just(value: 1) }.gated().loweredGraph()
        let verbose = Group(gate: true) { Just(value: 1) }.loweredGraph()
        XCTAssertEqual(sugar, verbose, PipelineGraphTestHelpers.prettyPrint(sugar))
    }

    // MARK: - Guardrail variadic

    func testGuardrailClassification_variadicRules_equalsArrayForm() {
        let variadic = GuardrailClassification(.politics, .pii) { Just(value: "hi") }.loweredGraph()
        let array = GuardrailClassification(rules: [.politics, .pii]) { Just(value: "hi") }.loweredGraph()
        XCTAssertEqual(variadic, array, PipelineGraphTestHelpers.prettyPrint(variadic))
    }

    // MARK: - assign(to:) dependency-capture contract

    /// `.assign(to:)` equals the *closure* `set { }` form when the producer's dependency is
    /// graph-encoded (`.input { $slot }`): the read lives in the graph, not in capturedReads.
    private struct GraphEncodedInput: Pipeline {
        typealias Output = String
        @State var source = "x"
        @State var dest = ""
        var body: some Pipeline {
            Model<String>("echo").input { $source }.assign(to: $dest)
            $dest
        }
    }

    private struct GraphEncodedInputClosure: Pipeline {
        typealias Output = String
        @State var source = "x"
        @State var dest = ""
        var body: some Pipeline {
            $dest.set { Model<String>("echo").input { $source } }
            $dest
        }
    }

    func testAssign_graphEncodedInput_equalsClosureSetForm() {
        XCTAssertEqual(
            PipelineGraphTestHelpers.shape(of: GraphEncodedInput().loweredGraph()),
            PipelineGraphTestHelpers.shape(of: GraphEncodedInputClosure().loweredGraph())
        )
    }

    /// When the producer bakes a bare `@State` read during construction (`.message(state)`),
    /// `.assign` (value form) does NOT capture it but `set { }` (closure form) does — they are
    /// deliberately different. This guards the documented contract on `Pipeline.assign(to:)`.
    private struct BakedStateAssign: Pipeline {
        typealias Output = String
        @State var source = "x"
        @State var dest = ""
        var body: some Pipeline {
            Model<String>("echo").message(source).assign(to: $dest)
            $dest
        }
    }

    private struct BakedStateClosure: Pipeline {
        typealias Output = String
        @State var source = "x"
        @State var dest = ""
        var body: some Pipeline {
            $dest.set { Model<String>("echo").message(source) }
            $dest
        }
    }

    func testAssign_bakedBareState_differsFromClosureSetForm() {
        // The closure form captures the `source` read as a dependency (an extra stateGet in the
        // lowered SetValue group); `.assign` does not. If these ever become equal, `.assign` has
        // silently changed its read-capture semantics.
        XCTAssertNotEqual(
            PipelineGraphTestHelpers.shape(of: BakedStateAssign().loweredGraph()),
            PipelineGraphTestHelpers.shape(of: BakedStateClosure().loweredGraph())
        )
    }
}
