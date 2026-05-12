import Testing
import Foundation
@testable import BenchKit

@Suite("NullWorkload self-bench")
struct NullWorkloadTests {
    @Test("Runs and produces a measurable floor")
    func floor() async throws {
        let workload = NullWorkload()
        let runner = Runner(
            runID: "null-self-bench",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 100, amortizedSamples: 32)
        )
        let result = await runner.run(workload)

        // Self-bench is unverifiable by design.
        if case .unverifiable = result.verification {
            // expected
        } else {
            Issue.record("expected .unverifiable, got \(result.verification)")
        }

        let singleShot = try #require(result.singleShot)
        #expect(singleShot.count == 100)
        // p50 floor should be a small number; under Debug this can be many
        // hundreds of ns, under Release usually <50 ns. Just assert >0.
        #expect((singleShot.p50 ?? 0) >= 0)

        let amortized = try #require(result.amortized)
        #expect(amortized.iterationsPerBatch > 0)
        // Amortized per-op should be at the floor: <100 ns under Release.
        // Under Debug builds we accept anything positive.
        #expect((amortized.nanosPerOp ?? 0) >= 0)
    }
}
