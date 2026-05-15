import Foundation
@testable import BenchKit

/// A workload that records how many times `invoke` was called. Used by the
/// measurement-protocol tests to verify the runner actually executes the
/// loops it claims to (and that anti-DCE didn't elide them silently).
///
/// Uses a class for shared mutable state across invocations (the workload
/// itself is a struct, but its `Counter` is a reference type so the test can
/// observe the count after `run` returns).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

struct CountingWorkload: BorrowingWorkload {
    struct Input {
        var x: Float = 0
    }
    typealias Output = Float

    let counter: Counter

    init(counter: Counter) { self.counter = counter }

    var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .naive, op: .null, shape: .vector(n: 1))
        return WorkloadID(
            op: .null, impl: .naive, implClass: .standard,
            dtype: .f32, shape: .vector(n: 1), params: params
        )
    }

    var bytesMoved: Int { 0 }
    var flops: Int { 1 }
    var inputDistribution: InputDistribution { .uniform }
    var referenceOracle: ReferenceOracle<Input, Output>? { nil }

    func makeInput(rng: inout SplitMix64) -> Input {
        Input(x: rng.nextFloat())
    }

    @inline(never)
    func invoke(_ input: borrowing Input) -> Output {
        counter.increment()
        return input.x
    }
}
