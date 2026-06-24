import Foundation

/// Monotonic counter: increments once per committed execution-slot write (lockstep server/client).
public typealias ExecutionEpoch = UInt64
