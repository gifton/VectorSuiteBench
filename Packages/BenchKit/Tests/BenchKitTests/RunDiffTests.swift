import Testing
import Foundation
@testable import BenchKit

@Suite("RunDiff")
struct RunDiffTests {
    @Test("Refuses to diff across hardware fingerprints")
    func refusesCrossFingerprint() {
        let a = makeRun(runID: "a", chip: "M3")
        let b = makeRun(runID: "b", chip: "M4")
        #expect(throws: RunDiff.Error.self) {
            _ = try RunDiff.compare(a: a, b: b)
        }
    }

    @Test("Pairs cases with matching IDs across two runs")
    func pairsByID() throws {
        let id1 = makeID(impl: .naive, n: 64)
        let id2 = makeID(impl: .naive, n: 128)
        let id3 = makeID(impl: .accelerate, n: 64)
        let a = makeRun(runID: "a", chip: "M3", cases: [
            makeCase(id: id1, runID: "a", p50: 100, gflops: 1.0),
            makeCase(id: id2, runID: "a", p50: 200, gflops: 0.5),
        ])
        let b = makeRun(runID: "b", chip: "M3", cases: [
            makeCase(id: id1, runID: "b", p50: 90, gflops: 1.1),     // improved
            makeCase(id: id3, runID: "b", p50: 80, gflops: 1.25),    // B-only
        ])
        let diff = try RunDiff.compare(a: a, b: b)
        #expect(diff.pairs.count == 3)
        let pair1 = diff.pairs.first { $0.id == id1 }!
        #expect(pair1.isComplete)
        #expect((pair1.singleShotP50Delta ?? 0) < 0)  // got faster

        let pair2 = diff.pairs.first { $0.id == id2 }!
        #expect(pair2.isMissingFromB)

        let pair3 = diff.pairs.first { $0.id == id3 }!
        #expect(pair3.isMissingFromA)
    }

    @Test("Markdown table includes all pairs with status column")
    func markdown() throws {
        let id = makeID(impl: .naive, n: 64)
        let a = makeRun(runID: "a", chip: "M3", cases: [
            makeCase(id: id, runID: "a", p50: 100, gflops: 1.0),
        ])
        let b = makeRun(runID: "b", chip: "M3", cases: [
            makeCase(id: id, runID: "b", p50: 50, gflops: 2.0),
        ])
        let diff = try RunDiff.compare(a: a, b: b)
        let md = diff.markdownTable()
        #expect(md.contains("dot"))
        #expect(md.contains("naive"))
        #expect(md.contains("vec(64)"))
        #expect(md.contains("-50.00%"))  // p50 halved
    }

    // MARK: - Fixtures

    private func makeID(impl: ImplKind, n: Int) -> WorkloadID {
        let params = try! CanonicalParams([:], impl: impl, op: .dot, shape: .vector(n: n))
        return WorkloadID(
            op: .dot, impl: impl, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    private func makeRun(runID: String, chip: String, cases: [CaseResult] = []) -> RunDocument {
        let hardware = HardwareInventory(
            chip: chip, pCoreCount: 4, eCoreCount: 4, gpuCoreCount: 0,
            memoryGB: 16, osVersion: "macOS test", xcodeBuild: "test",
            swiftVersion: "6.0"
        )
        let metadata = RunMetadata(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            preset: .smoke,
            git: GitProvenance(sha: "abc", branch: "main", dirty: false),
            build: BuildProvenance.probe(),
            hardware: hardware,
            linkedLibraryVersions: [:],
            fpcrAtStart: 0,
            lowPowerModeEnabled: false,
            timerOverheadNanos: 41.6,
            harnessOverheadNanos: nil,
            seedTableVersion: SeedTable.version
        )
        return RunDocument(runMetadata: metadata, cases: cases)
    }

    private func makeCase(id: WorkloadID, runID: String, p50: UInt64, gflops: Double) -> CaseResult {
        CaseResult(
            id: id,
            singleShot: LatencyDistribution(samples: [p50]),
            amortized: nil,
            bandwidthGBPerSec: gflops * 4,  // arbitrary; only checking ratios in tests
            gflops: gflops,
            preSampleRSS: 0, postSampleRSS: 0,
            memoryTrace: [], thermalEvents: [],
            timerOverheadNanos: 41.6,
            verification: .verified(maxUlpObserved: 1),
            flags: [],
            runID: runID
        )
    }
}
