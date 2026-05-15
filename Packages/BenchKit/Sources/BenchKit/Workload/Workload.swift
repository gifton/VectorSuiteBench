import Foundation

// MARK: - RunnableWorkload (parent protocol; existential-to-concrete dispatch)

/// Parent protocol that the three typed workload protocols refine. Exists so
/// the registry can hold `[any RunnableWorkload]` and dispatch each case to
/// the right runner through protocol-witness specialization — without the
/// orchestrator needing to know whether a given case is sync-borrowing,
/// sync-mutating, or async.
///
/// The default `runVia(...)` implementations are provided per typed protocol
/// below. Each implementation forwards to `Runner.run(_:)` or
/// `AsyncRunner.run(_:)` with the concrete `Self`, so the runner's generic
/// specialization happens at the witness call site — no `any`-typed inner
/// loop, no forced casts.
public protocol RunnableWorkload: WorkloadMetadata {
    /// Dispatch this workload through whichever runner is appropriate for
    /// its protocol shape. The default implementation on each typed protocol
    /// routes to the right runner; user code should not override this.
    func runVia(
        runner: Runner,
        asyncRunner: AsyncRunner,
        cancellation: CancellationToken?
    ) async -> CaseResult
}

// MARK: - BorrowingWorkload

/// A read-only workload (dot, l2dist, cosine, out-of-place normalize, …).
/// Swift 6 `borrowing` ensures the same `Input` is safely reused across all
/// K iterations of Amortized mode without aliasing concerns.
public protocol BorrowingWorkload: RunnableWorkload {
    associatedtype Input
    associatedtype Output

    /// Typed reference oracle. `nil` for workloads with no semantic output
    /// to verify (e.g., `NullWorkload`). Workloads with non-nil oracles
    /// MUST have their output verified before perf sampling.
    var referenceOracle: ReferenceOracle<Input, Output>? { get }

    /// Build a single deterministic input. Called once per case.
    func makeInput(rng: inout SplitMix64) -> Input

    /// The hot path. Must be allocation-free; results must be consumed via
    /// `BlackHole.consume` by the runner (anti-DCE).
    func invoke(_ input: borrowing Input) -> Output
}

extension BorrowingWorkload {
    public func runVia(
        runner: Runner,
        asyncRunner: AsyncRunner,
        cancellation: CancellationToken?
    ) async -> CaseResult {
        await runner.run(self, cancellation: cancellation)
    }
}

// MARK: - MutatingWorkload

/// A workload whose `invoke` mutates its input (axpy, in-place normalize, …).
///
/// In Amortized mode the runner pre-allocates K independent inputs via
/// `makeInputs(count: K, rng:)`, snapshots them, and restores per sample —
/// re-using a single mutated input across thousands of iterations drifts
/// toward NaN/Inf, triggering severe microcode penalties.
///
/// In single-shot mode the runner pre-allocates N inputs (one per sample)
/// and consumes one per timed call. The build cost lives outside the timing
/// window.
public protocol MutatingWorkload: RunnableWorkload {
    associatedtype Input
    associatedtype Output

    var referenceOracle: ReferenceOracle<Input, Output>? { get }

    /// Build `count` independent deterministic inputs.
    func makeInputs(count K: Int, rng: inout SplitMix64) -> [Input]

    /// The hot path; input is rotated per iteration, never reused.
    func invoke(_ input: inout Input) -> Output
}

extension MutatingWorkload {
    public func runVia(
        runner: Runner,
        asyncRunner: AsyncRunner,
        cancellation: CancellationToken?
    ) async -> CaseResult {
        await runner.run(self, cancellation: cancellation)
    }
}

// MARK: - AsyncWorkload

/// A workload whose performance depends on internal parallelism (`Operations`
/// / `BatchOperations` entry points). Sync wrappers would defeat the
/// TaskGroup-based parallelism we're trying to measure.
///
/// Async/throws overhead is acceptable here because these ops are
/// large-grained (≥µs) by definition.
public protocol AsyncWorkload: RunnableWorkload {
    associatedtype Input
    associatedtype Output

    var referenceOracle: ReferenceOracle<Input, Output>? { get }

    func makeInput(rng: inout SplitMix64) async -> Input
    func invoke(_ input: inout Input) async throws -> Output
}

extension AsyncWorkload {
    public func runVia(
        runner: Runner,
        asyncRunner: AsyncRunner,
        cancellation: CancellationToken?
    ) async -> CaseResult {
        await asyncRunner.run(self, cancellation: cancellation)
    }
}
