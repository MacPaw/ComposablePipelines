//
//  PathJail.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Confines every file path the agent touches to a single working directory.
///
/// A path argument from the model is resolved against `root`, standardized (so `..` segments are
/// collapsed), and rejected unless it stays inside `root`. Absolute paths are allowed only when
/// they already point inside `root`. This is the agent's primary safety boundary.
public struct PathJail: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    public enum JailError: Error, CustomStringConvertible {
        case escapes(String)
        public var description: String {
            switch self {
            case .escapes(let p): return "path '\(p)' escapes the working directory"
            }
        }
    }

    /// Resolve a model-supplied path to an absolute URL inside `root`, or throw `JailError.escapes`.
    ///
    /// Symlinks are resolved before the containment check, so a symlink created *inside* the jail
    /// (e.g. via `bash`) cannot redirect a read/write outside it. `root` is already symlink-resolved
    /// in `init`, so the comparison is realpath-to-realpath. For a not-yet-existing leaf the existing
    /// parent prefix is still resolved — which is what matters for write targets.
    public func resolve(_ path: String) throws -> URL {
        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        // Collapse "."/".." first, then resolve the *parent's* real path — `resolvingSymlinksInPath`
        // stops at the first non-existent component, so resolving the parent (which normally exists)
        // is what catches a write to a new file *through* a symlinked directory. Finally resolve the
        // leaf itself if it is a symlink. A symlink inside the jail thus cannot redirect access out.
        let standardized = candidate.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var resolved = parent.appendingPathComponent(standardized.lastPathComponent)
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path) {
            let target = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : parent.appendingPathComponent(dest)
            resolved = target.resolvingSymlinksInPath().standardizedFileURL
        }
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolved.path == rootPath || resolved.path.hasPrefix(prefix) else {
            throw JailError.escapes(path)
        }
        return resolved
    }

    /// Path relative to `root` for display (e.g. in tool output), falling back to the full path.
    public func display(_ url: URL) -> String {
        let full = url.standardizedFileURL.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if full.hasPrefix(prefix) { return String(full.dropFirst(prefix.count)) }
        return full
    }
}
