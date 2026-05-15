import Foundation

/// The harness's self-bench. `invoke` does nothing measurable — its cost is
/// the floor for the entire measurement stack: clock read + BlackHole
/// consume + Runner per-iteration overhead.
///
/// Recorded as `RunMetadata.harnessOverheadNanos`. If this number grows
/// >10 % run-over-run, **BenchKit itself has regressed** — not the library
/// under test. Visible in every run's Summary view.
///
/// **Verification**: declares no `referenceOracle`. The verification step
/// returns `.unverifiable(reason: "self-bench has no semantic output")` and
/// the runner proceeds to sample normally.
public struct NullWorkload: BorrowingWorkload {
    public struct Input {
        public var counter: UInt64
        public init(counter: UInt64 = 0) { self.counter = counter }
    }
    public typealias Output = UInt64

    public init() {}

    public var identifier: WorkloadID {
        // OpKind.null is the dedicated sentinel for the harness self-bench.
        // It is excluded from every real chart filter by construction.
        let params = try! CanonicalParams(
            [:],
            impl: .naive,
            op: .null,
            shape: .vector(n: 1)
        )
        return WorkloadID(
            op: .null,
            impl: .naive,
            implClass: .standard,
            dtype: .f32,
            shape: .vector(n: 1),
            params: params
        )
    }

    public var bytesMoved: Int { 0 }
    public var flops: Int { 1 }    // one integer add — keeps GFLOP/s derivation honest (sentinel)
    public var inputDistribution: InputDistribution { .uniform }

    /// No oracle. Self-bench is unverifiable by design — verification will
    /// report `.unverifiable("no reference oracle declared")` and the runner
    /// proceeds to sample normally.
    public var referenceOracle: ReferenceOracle<Input, Output>? { nil }

    public func makeInput(rng: inout SplitMix64) -> Input {
        Input(counter: rng.next())
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        // Minimum work: one integer add. Anything less and the optimizer
        // collapses the entire call chain (BlackHole still saves us, but
        // the floor measurement becomes meaningless).
        return input.counter &+ 1
    }
}
