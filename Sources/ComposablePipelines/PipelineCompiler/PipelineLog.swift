//
//  PipelineLog.swift
//  elix-toolchain
//
//  Open logging seam — the package's replacement for the LoggingCore `Logger` dependency.
//

import Foundation

/// Lightweight, backend-agnostic logging seam for the open package.
///
/// A host injects a `PipelineLog` to receive compiler/walker diagnostics; the default ``none`` is
/// silent, so the package logs nothing unless asked. The proprietary runtime bridges this to its
/// real logger. Mirrors the small slice of `Logger` the package used (`subLogger`, `log`).
public struct PipelineLog: Sendable {

    public enum Level: Sendable { case verbose, debug, info, warning, error }

    public typealias Sink = @Sendable (
        _ level: Level, _ category: String, _ message: String, _ metadata: [String: String]
    ) -> Void

    private let category: String
    private let sink: Sink

    private init(category: String, sink: @escaping Sink) {
        self.category = category
        self.sink = sink
    }

    public init(_ sink: @escaping Sink) {
        self.init(category: "", sink: sink)
    }

    /// Silent default — the package emits no diagnostics.
    public static let none = PipelineLog { _, _, _, _ in }

    /// A child log carrying a dotted sub-category (mirrors `Logger.subLogger`).
    public func subLogger(_ name: String) -> PipelineLog {
        PipelineLog(category: category.isEmpty ? name : "\(category).\(name)", sink: sink)
    }

    public func log(_ level: Level, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        sink(level, category, message(), metadata)
    }
}
