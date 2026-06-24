//
//  ExecutionContext.swift
//  elix-toolchain
//
//  Created by Maxim Kotliar on 23.04.2026.
//

import Foundation
import PipelineAST

public struct ExecutionContext: @unchecked Sendable {

    @TaskLocal @_spi(Internals) public static var current: ExecutionContext?
    @TaskLocal @_spi(Internals) public static var isEmittingPipelineGraph: Bool = false
    @TaskLocal @_spi(Internals) public static var isExecutingClientTask: Bool = false
    /// Epoch used for as-of reads while lowering a graph (lockstep with committed epoch after remote updates).
    @TaskLocal @_spi(Internals) public static var executionEpoch: ExecutionEpoch = 0
    private let committedEpochStorage = Synchronized<ExecutionEpoch>(wrappedValue: 0)

    /// Latest committed epoch from applied server updates (or local simulation).
    public var committedEpoch: ExecutionEpoch {
        committedEpochStorage.wrappedValue
    }

    @Synchronized var bindings: [UUID: Data] = [:]
    /// Append-only history per slot: `(epoch, encoded value)` sorted by epoch ascending.
    @Synchronized var slotHistory: [UUID: [(epoch: ExecutionEpoch, value: Data)]] = [:]

    @_spi(Internals) public init() {}

    @_spi(Internals) public func _set(_ value: Data, for key: UUID) {
        $bindings[key] = value
    }

    /// Apply remote (or simulated) slot writes with lockstep epochs. Sorts by `(epoch, slotID)` for determinism.
    ///
    /// ``StateWriteKind/commit`` updates append to ``slotHistory`` and advance ``committedEpoch``.
    /// ``StateWriteKind/draft`` updates only refresh ``bindings`` (live preview) without touching history or epoch.
    @_spi(Internals) public func applyStateUpdatesFromRemote(_ epochBySlot: [(slotID: UUID, epoch: ExecutionEpoch, value: Data)]) {
        applyStateUpdatesFromRemote(
            epochBySlot.map { (slotID: $0.slotID, epoch: $0.epoch, value: $0.value, kind: StateWriteKind.commit) }
        )
    }

    @_spi(Internals) public func applyStateUpdatesFromRemote(
        _ entries: [(slotID: UUID, epoch: ExecutionEpoch, value: Data, kind: StateWriteKind)]
    ) {
        let sorted = entries.sorted {
            if $0.epoch != $1.epoch { return $0.epoch < $1.epoch }
            return $0.slotID.uuidString < $1.slotID.uuidString
        }
        var maxEpoch = committedEpochStorage.wrappedValue
        for entry in sorted {
            switch entry.kind {
            case .draft:
                $bindings.write { map in
                    map[entry.slotID] = entry.value
                }
            case .commit:
                $slotHistory.write { map in
                    var hist = map[entry.slotID] ?? []
                    hist.append((epoch: entry.epoch, value: entry.value))
                    map[entry.slotID] = hist
                }
                $bindings.write { map in
                    map[entry.slotID] = entry.value
                }
                maxEpoch = max(maxEpoch, entry.epoch)
            }
        }
        committedEpochStorage.store(maxEpoch)
    }

    /// Value visible at `executionEpoch`: last history entry with `epoch <= executionEpoch`, else bindings, else nil.
    @_spi(Internals) public func asOfData(slotID: UUID, executionEpoch: ExecutionEpoch) -> Data? {
        let hist = slotHistory[slotID] ?? []
        if let pair = hist.last(where: { $0.epoch <= executionEpoch }) {
            return pair.value
        }
        return bindings[slotID]
    }

    /// Latest bytes for ``slotID`` (last appended commit for that slot, else live ``bindings``).
    ///
    /// Client tasks that run **after** the ElixEngine applies a commit batch often need this instead of
    /// ``asOfData(slotID:executionEpoch:)`` with ``committedEpoch``: batched epoch ordering can leave
    /// ``asOfData`` without a matching history row even though ``bindings`` already holds the value.
    @_spi(Internals) public func latestSlotBytes(slotID: UUID) -> Data? {
        let hist = slotHistory[slotID] ?? []
        if let last = hist.last {
            return last.value
        }
        return bindings[slotID]
    }
}
