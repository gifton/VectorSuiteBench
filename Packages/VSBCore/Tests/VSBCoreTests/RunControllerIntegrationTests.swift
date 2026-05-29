import Testing
import Foundation
@testable import VSBCore
@testable import BenchKit

@Suite("RunController × VSBCoreRegistry integration")
struct RunControllerIntegrationTests {

    /// Drives a *filtered* slice of the real VSBCoreRegistry through
    /// RunController and asserts the existential-dispatch path produces a
    /// well-formed RunDocument on disk. Phase 2.0 Item 1 acceptance criterion:
    /// closes the loop on `[any RunnableWorkload]` → `runVia(...)` →
    /// runner specialization → `RunStore.finalizeRun`.
    @Test("Filtered registry produces a valid RunDocument on disk")
    func smallEndToEnd() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)

        // Take only the smallest baseline dot cases (N=64) so wall time
        // stays well under the smoke budget. Three baseline impls × N=64 = 3
        // cases. Restricted to op=.dot so subsequent op-family additions
        // (l2dist in 2.2 Item 1a, cosine in 1b, etc.) don't perturb this
        // integration test's case count.
        let filtered = VSBCoreRegistry.workloads.filter {
            $0.identifier.op == .dot
                && $0.identifier.shape == .vector(n: 64)
                && $0.identifier.impl != .vectorCore
        }
        #expect(filtered.count == 3, "expected 3 baseline dot cases at N=64; got \(filtered.count)")

        let controller = RunController(
            registry: filtered,
            store: store,
            preset: .smoke,
            allowDebugBuildsForTesting: true,
            measurePeaks: false      // keep the harness self-bench fast in tests
        )
        let document = try await controller.run()

        // Document shape.
        #expect(document.schemaVersion == .current)
        #expect(document.cases.count == filtered.count)
        #expect(document.runMetadata.runID == controller.runID)

        // Every case verified (or unverifiable for cases with no oracle —
        // shouldn't occur in this filter, but the assertion stays generic).
        for c in document.cases {
            switch c.verification {
            case .verified, .unverifiable:
                continue
            case .failed(let maxUlp, let window, let idx):
                Issue.record(
                    Comment(rawValue: "\(c.id.canonicalString) failed: ulp=\(maxUlp) window=\(window) sampleIdx=\(idx)")
                )
            }
        }

        // Metadata fields populated.
        #expect(!document.runMetadata.hardware.fingerprint.isEmpty)
        #expect(document.runMetadata.seedTableVersion == SeedTable.version)
        // `timerOverheadNanos` is recorded as context. On Apple Silicon the
        // mach_absolute_time tick (~41.6 ns) is coarser than a back-to-back
        // pair of reads, so a *median* delta of 0 is legitimate and not a
        // bug — just verify the field is non-negative.
        #expect(document.runMetadata.timerOverheadNanos >= 0)
        // Harness floor measured (non-nil) — confirms NullWorkload self-bench ran.
        #expect(document.runMetadata.harnessOverheadNanos != nil)

        // Disk artifacts present.
        #expect(FileManager.default.fileExists(atPath: store.manifestURL(for: controller.runID).path))
        let casesDir = store.casesDirectory(for: controller.runID)
        let caseFiles = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { $0.hasSuffix(".json") }
        #expect(caseFiles.count == filtered.count)

        // index.json updated.
        let index = try store.loadIndex()
        #expect(index.runs.contains(where: { $0.runID == controller.runID }))
    }

    @Test("Cancellation between cases produces a valid partial document")
    func cancellation() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)

        let filtered = VSBCoreRegistry.workloads.filter {
            $0.identifier.op == .dot
                && $0.identifier.shape == .vector(n: 64)
                && $0.identifier.impl != .vectorCore
        }
        #expect(filtered.count >= 2)

        let token = CancellationToken()
        let controller = RunController(
            registry: filtered,
            store: store,
            preset: .smoke,
            cancellation: token,
            allowDebugBuildsForTesting: true,
            measurePeaks: false
        )

        // Cancel *before* run() — every case after the first check is skipped.
        // This deterministic form exercises the queue-level cancellation
        // path without racing the harness self-bench.
        token.cancel()
        let document = try await controller.run()

        // Manifest written, queue skipped entirely (or up to wherever the
        // pre-case check ran). Document is still loadable — that's the
        // contract: "a cancelled run is a valid run on disk".
        #expect(document.cases.count == 0)
        #expect(FileManager.default.fileExists(atPath: store.manifestURL(for: controller.runID).path))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSBCoreRunControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
