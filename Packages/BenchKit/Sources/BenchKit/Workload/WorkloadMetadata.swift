import Foundation

/// Metadata common to all workload protocol variants. The type-erased
/// existential `any WorkloadMetadata` is what the registry holds for
/// enumeration; the Runner dispatches to a generic `run<W>` instantiation
/// per case, which then accesses the typed `referenceOracle`.
///
/// **Note**: `referenceOracle` deliberately lives on the typed Workload
/// protocols (`BorrowingWorkload`, `MutatingWorkload`, `AsyncWorkload`),
/// not on this metadata existential. Carrying the oracle here would force
/// `Any` erasure of `Input`/`Output`; we want compile-time type safety on
/// the verification path.
public protocol WorkloadMetadata: Sendable {
    var identifier: WorkloadID { get }
    var bytesMoved: Int { get }
    var flops: Int { get }
    var inputDistribution: InputDistribution { get }
}
