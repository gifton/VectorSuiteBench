import Foundation

/// Metadata common to all workload protocol variants (`BorrowingWorkload`,
/// `MutatingWorkload`, `AsyncWorkload`).
///
/// `identifier`, `bytesMoved`, `flops`, and `inputDistribution` are pure
/// metadata used by the runner for case enumeration, GB/s and GFLOP/s
/// derivation, and historical comparison. `referenceOracle` is mandatory for
/// every dense floating-point workload (workloads without one fail registry
/// validation at startup). ULP tolerance is **not** stored here — it's a
/// shape-dependent function (`ulpTolerance(op:implClass:shape:)`) so a single
/// workload type doesn't need to know its full set of resolved tolerances
/// across all sizes it'll run at.
public protocol WorkloadMetadata: Sendable {
    var identifier: WorkloadID { get }
    var bytesMoved: Int { get }
    var flops: Int { get }
    var inputDistribution: InputDistribution { get }
    var referenceOracle: ReferenceOracle? { get }
}
