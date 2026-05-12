import Foundation

// MARK: - BorrowingWorkload

/// A read-only workload (dot, l2dist, cosine, out-of-place normalize, …).
/// Swift 6 `borrowing` ensures the same `Input` is safely reused across all
/// K iterations of Amortized mode without aliasing concerns.
public protocol BorrowingWorkload: WorkloadMetadata {
    associatedtype Input
    associatedtype Output

    /// Build a single deterministic input. Called once per case.
    func makeInput(rng: inout SplitMix64) -> Input

    /// The hot path. Must be allocation-free; results must be consumed via
    /// `BlackHole.consume` by the runner (anti-DCE).
    func invoke(_ input: borrowing Input) -> Output
}

// MARK: - MutatingWorkload

/// A workload whose `invoke` mutates its input (axpy, in-place normalize, …).
///
/// In Amortized mode the runner pre-allocates K independent inputs via
/// `makeInputs(count: K, rng:)` and rotates per iteration — re-using a single
/// mutated input across thousands of iterations drifts toward NaN/Inf,
/// triggering severe microcode penalties for denormal/NaN math and corrupting
/// the measurement.
///
/// In single-shot mode the runner pre-allocates N inputs (one per sample) and
/// consumes one per timed call. The build cost lives outside the timing
/// window.
public protocol MutatingWorkload: WorkloadMetadata {
    associatedtype Input
    associatedtype Output

    /// Build `count` independent deterministic inputs.
    func makeInputs(count K: Int, rng: inout SplitMix64) -> [Input]

    /// The hot path; input is rotated per iteration, never reused.
    func invoke(_ input: inout Input) -> Output
}

// MARK: - AsyncWorkload

/// A workload whose performance depends on internal parallelism (`Operations`
/// / `BatchOperations` entry points). Sync wrappers would defeat the
/// TaskGroup-based parallelism we're trying to measure.
///
/// Async/throws overhead is acceptable here because these ops are
/// large-grained (≥µs) by definition.
public protocol AsyncWorkload: WorkloadMetadata {
    associatedtype Input
    associatedtype Output

    func makeInput(rng: inout SplitMix64) async -> Input
    func invoke(_ input: inout Input) async throws -> Output
}
