import Testing
import Foundation
@testable import BenchKit

@Suite("RunStore")
struct RunStoreTests {
    @Test("Begin run, write case, finalize, reload")
    func roundTrip() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)

        let metadata = makeMetadata(runID: "round-trip-1")
        try store.beginRun(metadata: metadata)
        #expect(FileManager.default.fileExists(atPath: store.manifestURL(for: metadata.runID).path))

        let result = makeCaseResult(runID: metadata.runID)
        try store.writeCase(result)
        let caseFile = store.caseURL(for: metadata.runID, caseHash: store.caseHash(for: result.id))
        #expect(FileManager.default.fileExists(atPath: caseFile.path))

        let doc = try store.finalizeRun(runID: metadata.runID)
        #expect(doc.schemaVersion == .current)
        #expect(doc.runMetadata.runID == metadata.runID)
        #expect(doc.cases.count == 1)
        #expect(doc.cases.first?.id == result.id)

        // Round-trip via loadRun.
        let reloaded = try store.loadRun(runID: metadata.runID)
        #expect(reloaded.cases.count == 1)
        #expect(reloaded.runMetadata.runID == metadata.runID)
    }

    @Test("index.json is updated atomically across multiple finalizations")
    func indexAggregation() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)

        for i in 0..<3 {
            let meta = makeMetadata(runID: "run-\(i)")
            try store.beginRun(metadata: meta)
            try store.writeCase(makeCaseResult(runID: meta.runID))
            _ = try store.finalizeRun(runID: meta.runID)
        }
        let index = try store.loadIndex()
        #expect(index.runs.count == 3)
        // Sorted newest first by timestamp; with identical timestamps the
        // contract is just "some stable order" — verify all three present.
        let ids = Set(index.runs.map(\.runID))
        #expect(ids == ["run-0", "run-1", "run-2"])
    }

    @Test("loadRun on missing runID throws")
    func loadMissing() {
        let tmp = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        #expect(throws: (any Error).self) {
            try store.loadRun(runID: "does-not-exist")
        }
    }

    @Test("wallTimeNanos round-trips through manifest, document, and index (schema 1.2)")
    func wallTimeRoundTrip() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)

        let metadata = makeMetadata(runID: "wall-time-1")
        try store.beginRun(metadata: metadata)
        try store.writeCase(makeCaseResult(runID: metadata.runID))

        let stamped: UInt64 = 12_345_678_900
        let doc = try store.finalizeRun(runID: metadata.runID, wallTimeNanos: stamped)
        #expect(doc.runMetadata.wallTimeNanos == stamped)

        // Manifest on disk reflects the stamp — loadRun returns the
        // patched value, not the pre-queue nil.
        let reloaded = try store.loadRun(runID: metadata.runID)
        #expect(reloaded.runMetadata.wallTimeNanos == stamped)

        // Index summary mirrors the metadata.
        let index = try store.loadIndex()
        let summary = try #require(index.runs.first { $0.runID == metadata.runID })
        #expect(summary.wallTimeNanos == stamped)
    }

    @Test("finalizeRun without wallTimeNanos leaves the field nil")
    func wallTimeOptionalDefault() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)

        let metadata = makeMetadata(runID: "wall-time-nil")
        try store.beginRun(metadata: metadata)
        try store.writeCase(makeCaseResult(runID: metadata.runID))
        let doc = try store.finalizeRun(runID: metadata.runID)
        #expect(doc.runMetadata.wallTimeNanos == nil)

        let index = try store.loadIndex()
        let summary = try #require(index.runs.first { $0.runID == metadata.runID })
        #expect(summary.wallTimeNanos == nil)
    }

    @Test("RunSummary decodes cleanly from pre-1.2 JSON (no wallTimeNanos key)")
    func runSummaryBackwardCompat() throws {
        // Pre-1.2 wire shape: no wallTimeNanos field. Optional Codable
        // fields decode `nil` for missing keys — assert that explicitly so
        // a future @Codable refactor that breaks this guarantee fails loudly.
        let json = #"""
        {
          "runID": "legacy",
          "timestamp": "2025-01-01T00:00:00Z",
          "gitSha": "deadbee",
          "branch": "main",
          "preset": "smoke",
          "caseCount": 1,
          "completedCaseCount": 1,
          "hardwareFingerprint": "test",
          "thermalEscalations": 0
        }
        """#
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(RunSummary.self, from: data)
        #expect(summary.wallTimeNanos == nil)
        #expect(summary.runID == "legacy")
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BenchKitRunStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMetadata(runID: String) -> RunMetadata {
        RunMetadata(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            preset: .smoke,
            git: GitProvenance(sha: "abc1234", branch: "test", dirty: false),
            build: BuildProvenance.probe(),
            hardware: HardwareInventory.probe(),
            linkedLibraryVersions: ["BenchKit": "0.1.0"],
            fpcrAtStart: 0,
            lowPowerModeEnabled: false,
            timerOverheadNanos: 41.6,
            harnessOverheadNanos: 5.0,
            seedTableVersion: SeedTable.version
        )
    }

    private func makeCaseResult(runID: String) -> CaseResult {
        let params = try! CanonicalParams([:], impl: .naive, op: .dot, shape: .vector(n: 64))
        let id = WorkloadID(
            op: .dot, impl: .naive, implClass: .standard,
            dtype: .f32, shape: .vector(n: 64), params: params
        )
        let dist = LatencyDistribution(samples: [100, 200, 300])
        return CaseResult(
            id: id,
            singleShot: dist,
            amortized: AmortizedResult(iterationsPerBatch: 1000, batchNanos: dist),
            bandwidthGBPerSec: 4.2,
            gflops: 2.1,
            preSampleRSS: 1024,
            postSampleRSS: 1024,
            memoryTrace: [],
            thermalEvents: [],
            timerOverheadNanos: 41.6,
            verification: .verified(maxUlpObserved: 2),
            flags: [],
            runID: runID
        )
    }
}

@Suite("SchemaVersion")
struct SchemaVersionTests {
    @Test("Encodes as 'major.minor' string")
    func encoding() throws {
        let v = SchemaVersion(major: 1, minor: 2)
        let data = try JSONEncoder().encode(v)
        let s = String(data: data, encoding: .utf8)!
        #expect(s == "\"1.2\"")
    }

    @Test("Decodes from 'major.minor' string")
    func decoding() throws {
        let data = "\"3.7\"".data(using: .utf8)!
        let v = try JSONDecoder().decode(SchemaVersion.self, from: data)
        #expect(v.major == 3)
        #expect(v.minor == 7)
    }

    @Test("Comparable orders correctly")
    func ordering() {
        #expect(SchemaVersion(major: 1, minor: 0) < SchemaVersion(major: 1, minor: 1))
        #expect(SchemaVersion(major: 1, minor: 9) < SchemaVersion(major: 2, minor: 0))
        #expect(SchemaVersion(major: 2, minor: 0) > SchemaVersion(major: 1, minor: 99))
    }
}
