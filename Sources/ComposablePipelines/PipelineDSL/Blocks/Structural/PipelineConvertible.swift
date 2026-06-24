//
//  PipelineConvertible.swift
//  EneyLocal
//
//  Created by Maxim Kotliar on 10.04.2026.
//

/// Values that can be lowered through the same ``Pipeline`` recording path (e.g. raw strings, bindings, or any ``Pipeline``).
public protocol PipelineConvertible {
    associatedtype Output = Self
    var representedAsPipeline: any Pipeline { get }
}

public protocol JustPipelineConvertible: PipelineConvertible where Self: Encodable {}
extension JustPipelineConvertible {
    public var representedAsPipeline: any Pipeline {
        Just(value: self)
    }
}

extension String: JustPipelineConvertible {}
extension Bool: JustPipelineConvertible {}
extension Int: JustPipelineConvertible {}
