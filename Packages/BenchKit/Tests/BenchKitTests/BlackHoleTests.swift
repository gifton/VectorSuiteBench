import Testing
import Foundation
@testable import BenchKit

/// Helper "candidate" workload-style function that the optimizer is most
/// motivated to elide if BlackHole isn't doing its job: a pure computation
/// whose result is "discarded." With BlackHole.consume, the call chain must
/// execute and the sink must advance.
@inline(never)
private func candidateCompute(_ x: Float) -> Float {
    // A computation that is *not* a compile-time constant (depends on `x`).
    return (x * 3.14159) + 1.0
}

@Suite("BlackHole anti-DCE")
struct BlackHoleTests {
    @Test("Consume advances the per-thread sink")
    func sinkAdvances() {
        let before = BlackHole.threadSinkValue()
        let v: Float = 42.0
        let result = candidateCompute(v)
        BlackHole.consume(result)
        let after = BlackHole.threadSinkValue()
        // If the optimizer had elided the chain, after == before (BlackHole.consume
        // wouldn't run, sink wouldn't change). Sink advancing proves the call
        // chain executed.
        #expect(after != before, "BlackHole.consume did not advance the sink — DCE may have elided the call")
    }

    @Test("Repeated consume produces distinct sink values")
    func sinkAccumulates() {
        // Start from a known baseline.
        let baseline = BlackHole.threadSinkValue()
        var prior = baseline
        var advancements = 0
        for i in 0..<100 {
            // Pass a non-constant value through a non-inlined function.
            BlackHole.consume(candidateCompute(Float(i)))
            let current = BlackHole.threadSinkValue()
            if current != prior {
                advancements += 1
                prior = current
            }
        }
        // At least most of the 100 consumes should produce a distinct value
        // (XOR-summing distinct Float bit-patterns into the sink).
        #expect(advancements >= 90, "expected ≥90 sink changes out of 100, got \(advancements)")
    }
}
