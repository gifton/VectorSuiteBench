import Testing
import Foundation
@testable import BenchKit

@Suite("Mutating runner smoke")
struct MutatingRunnerSmokeTests {
    @Test("Mutating workload runs end-to-end with K-input rotation")
    func mutatingEndToEnd() throws {
        let workload = NormalizeInPlaceSmokeWorkload(n: 256)
        let runner = Runner(
            runID: "mutating-smoke",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 32, amortizedSamples: 8)
        )
        let result = runner.run(workload)

        #expect(result.verification.isVerified, "verification failed: \(result.verification)")
        let singleShot = try #require(result.singleShot)
        #expect(singleShot.count == 32)
        let amortized = try #require(result.amortized)
        #expect(amortized.iterationsPerBatch > 0)
        #expect(!result.flags.contains(.truncated))
    }
}

@Suite("Async runner smoke")
struct AsyncRunnerSmokeTests {
    @Test("Async workload runs end-to-end")
    func asyncEndToEnd() async throws {
        let workload = AsyncDotSmokeWorkload(n: 256)
        let runner = AsyncRunner(
            runID: "async-smoke",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 16, amortizedSamples: 4)
        )
        let result = await runner.run(workload)

        #expect(result.verification.isVerified, "verification failed: \(result.verification)")
        let singleShot = try #require(result.singleShot)
        #expect(singleShot.count == 16)
        let amortized = try #require(result.amortized)
        #expect(amortized.iterationsPerBatch > 0)
        #expect(!result.flags.contains(.truncated))
    }
}
