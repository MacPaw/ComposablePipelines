//
//  DelegateStatus.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Lifecycle phase of a single subagent, as seen by the observation layer.
public enum DelegatePhase: String, Codable, Sendable, Hashable {
    case pending
    case running
    case completed
    case refused   // budget-exhausted: never spawned
    case failed
}

/// The typed status a subagent **publishes upward** — the `PreferenceKey` value of the delegate. Small
/// by design (identity, phase, cost), never the transcript.
public struct DelegateStatus: Codable, Sendable, Hashable {
    public var runID: DelegateRunID
    public var phase: DelegatePhase
    /// Rough tokens/work spent so far, for duty-cycle accounting.
    public var cost: Int

    public init(runID: DelegateRunID, phase: DelegatePhase, cost: Int = 0) {
        self.runID = runID
        self.phase = phase
        self.cost = cost
    }
}

/// The folded aggregate for one `executionEpoch` — the delegate's analog of SwiftUI's per-render-pass
/// preference reduction. Sibling statuses are folded (last write per ``DelegateRunID`` wins) and the
/// result is tagged with the epoch, so a reduce over a *changing* membership set yields one consistent
/// snapshot per epoch.
///
/// Backpressure/resource signals are folded in by Phase 3.6.
public struct DelegateSnapshot: Codable, Sendable, Hashable {
    public var epoch: Int
    /// One status per subagent, ordered by tree position.
    public var statuses: [DelegateStatus]
    /// Resource/backpressure signals at this epoch (Phase 3.6).
    public var backpressure: DelegateBackpressure

    public init(epoch: Int, statuses: [DelegateStatus] = [], backpressure: DelegateBackpressure = .none) {
        self.epoch = epoch
        self.statuses = statuses
        self.backpressure = backpressure
    }

    /// Fold raw published statuses into a per-epoch snapshot: dedup by ``DelegateRunID`` (last wins),
    /// ordered by tree position for a stable view, with the epoch's backpressure signals attached.
    public static func reduce(
        epoch: Int,
        _ raw: [DelegateStatus],
        backpressure: DelegateBackpressure = .none
    ) -> DelegateSnapshot {
        var byID: [DelegateRunID: DelegateStatus] = [:]
        for status in raw { byID[status.runID] = status }
        let ordered = byID.values.sorted {
            $0.runID.path.lexicographicallyPrecedes($1.runID.path)
        }
        return DelegateSnapshot(epoch: epoch, statuses: ordered, backpressure: backpressure)
    }

    /// The status of a specific subagent, if present.
    public func status(for id: DelegateRunID) -> DelegateStatus? {
        statuses.first { $0.runID == id }
    }

    /// Subagents currently doing work.
    public var activeCount: Int {
        statuses.filter { $0.phase == .running }.count
    }
}

/// The **sink** subagents publish their status into during a run. It accumulates the latest status per
/// subagent and folds a consistent ``DelegateSnapshot`` on demand for the current epoch.
///
/// This is the sink half of the sink-and-fold the 3.1 spike showed is required (a child's `@State`
/// can't be read by the parent, so live status must be pushed into a shared sink). The live delegate
/// threads this down to subagents and reads snapshots up through a ``DelegateReader``.
public actor DelegateStatusSink {
    private var latest: [DelegateRunID: DelegateStatus] = [:]

    public init() {}

    /// Publish (or overwrite) a subagent's current status.
    public func publish(_ status: DelegateStatus) {
        latest[status.runID] = status
    }

    /// Drop all accumulated statuses — call between runs so a fresh delegate starts empty.
    public func reset() {
        latest.removeAll()
    }

    /// Fold everything published so far into a snapshot for `epoch`, attaching backpressure signals.
    public func snapshot(epoch: Int, backpressure: DelegateBackpressure = .none) -> DelegateSnapshot {
        DelegateSnapshot.reduce(epoch: epoch, Array(latest.values), backpressure: backpressure)
    }

    /// Fold a streamed primitive delegate event (as delivered by `ElixClientConfiguration.onDelegateEvent`)
    /// into the sink. Ignores an unrecognized phase string.
    public func publish(path: [Int], phaseRawValue: String, cost: Int) {
        guard let phase = DelegatePhase(rawValue: phaseRawValue) else { return }
        publish(DelegateStatus(runID: DelegateRunID(path: path), phase: phase, cost: cost))
    }
}
