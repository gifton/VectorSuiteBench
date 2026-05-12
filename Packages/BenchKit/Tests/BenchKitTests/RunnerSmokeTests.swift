import Testing
import Foundation
@testable import BenchKit

@Suite("Runner smoke test")
struct RunnerSmokeTests {
    @Test("Runner produces a verified result for a naive dot")
    func endToEnd() throws {
        let workload = DotSmokeWorkload(n: 512)
        let runner = Runner(
            runID: "smoke-test",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 64, amortizedSamples: 16)
        )
        let result = runner.run(workload)
        #expect(result.verification.isVerified, "verification failed: \(result.verification)")

        let singleShot = try #require(result.singleShot)
        #expect(singleShot.count == 64)
        #expect((singleShot.p50 ?? 0) > 0)

        let amortized = try #require(result.amortized)
        #expect(amortized.iterationsPerBatch > 0)
        #expect((amortized.nanosPerOp ?? 0) > 0)

        #expect(result.bandwidthGBPerSec > 0)
        #expect(result.gflops > 0)
        #expect(!result.flags.contains(.truncated))
    }

    @Test("Cancellation truncates the in-flight case")
    func cancellation() throws {
        let workload = DotSmokeWorkload(n: 64)
        let token = CancellationToken()
        token.cancel()
        let runner = Runner(
            runID: "cancel-test",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 1000, amortizedSamples: 100)
        )
        let result = runner.run(workload, cancellation: token)
        #expect(result.flags.contains(.truncated))
    }
}
