import Testing
import Foundation
@testable import BenchKit

@Suite("CSVExporter")
struct CSVExporterTests {

    @Test("Header carries schemaVersion, runID, and the frozen column manifest")
    func headerShape() {
        let doc = makeDocument(runID: "csv-header-1", cases: [])
        let csv = CSVExporter.render(doc)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        // Three comment lines, no data rows (empty cases).
        #expect(lines.count >= 3)
        #expect(lines[0] == "# schemaVersion: \(SchemaVersion.current.description)")
        #expect(lines[1] == "# runID: csv-header-1")
        #expect(lines[2] == "# columns: " + CSVExporter.columns.joined(separator: ","))
    }

    @Test("Cases with both modes produce two rows; single-mode produces one")
    func rowsPerMode() {
        let dist = LatencyDistribution(samples: [100, 200, 300, 400])
        let dual = makeCase(id: makeID(n: 64), single: dist, amortized: AmortizedResult(iterationsPerBatch: 1000, batchNanos: LatencyDistribution(samples: [1_000_000, 2_000_000])))
        let single = makeCase(id: makeID(n: 128), single: dist, amortized: nil)
        let amortizedOnly = makeCase(id: makeID(n: 256), single: nil, amortized: AmortizedResult(iterationsPerBatch: 500, batchNanos: LatencyDistribution(samples: [500_000])))

        let doc = makeDocument(runID: "rows-1", cases: [dual, single, amortizedOnly])
        let csv = CSVExporter.render(doc)
        let dataLines = csv.split(separator: "\n").filter { !$0.hasPrefix("#") }
        // dual: 2 rows; single: 1 row; amortizedOnly: 1 row. = 4 total.
        #expect(dataLines.count == 4)

        // First case appears twice with distinct mode columns.
        let dualRows = dataLines.filter { $0.contains("vec(64)") }
        #expect(dualRows.count == 2)
        #expect(dualRows.contains(where: { $0.contains(",single_shot,") }))
        #expect(dualRows.contains(where: { $0.contains(",amortized,") }))
    }

    @Test("Amortized percentiles are reported per-op (loop / K)")
    func amortizedPerOp() {
        // K = 1000, loop median = 1_000_000 ns → per-op = 1000 ns
        let amortized = AmortizedResult(
            iterationsPerBatch: 1000,
            batchNanos: LatencyDistribution(samples: [1_000_000])
        )
        let c = makeCase(id: makeID(n: 64), single: nil, amortized: amortized)
        let doc = makeDocument(runID: "amort-1", cases: [c])
        let csv = CSVExporter.render(doc)
        let dataLine = csv.split(separator: "\n").first(where: { !$0.hasPrefix("#") })!
        let cells = dataLine.split(separator: ",", omittingEmptySubsequences: false)
        // Columns: 0:op 1:impl 2:implClass 3:dtype 4:shape 5:params 6:mode 7:p50 8:p99 9:p999 ...
        #expect(cells[6] == "amortized")
        #expect(cells[7] == "1000",
                "amortized p50 must report per-op nanos (1_000_000 / 1000 = 1000), got \(cells[7])")
    }

    @Test("nil bandwidth and gflops render as empty cells")
    func nilDerivedFields() {
        let dist = LatencyDistribution(samples: [100])
        let c = CaseResult(
            id: makeID(n: 64),
            singleShot: dist,
            amortized: nil,
            bandwidthGBPerSec: nil,
            gflops: nil,
            preSampleRSS: 0, postSampleRSS: 0,
            memoryTrace: [], thermalEvents: [],
            timerOverheadNanos: 41.6,
            verification: .verified(maxUlpObserved: 0),
            flags: [],
            runID: "nil-derived"
        )
        let doc = makeDocument(runID: "nil-derived", cases: [c])
        let csv = CSVExporter.render(doc)
        let line = csv.split(separator: "\n").first(where: { !$0.hasPrefix("#") })!
        // Columns 10 (gflops) and 11 (bandwidth_gb_s) must be the empty string,
        // appearing as two adjacent commas in the rendered output.
        let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(cells[10] == "")
        #expect(cells[11] == "")
    }

    @Test("Flags are sorted in the rendered cell for stable diffs")
    func flagsSorted() {
        let dist = LatencyDistribution(samples: [100])
        let c = CaseResult(
            id: makeID(n: 64),
            singleShot: dist,
            amortized: nil,
            bandwidthGBPerSec: nil, gflops: nil,
            preSampleRSS: 0, postSampleRSS: 0,
            memoryTrace: [], thermalEvents: [],
            timerOverheadNanos: 0,
            verification: .verified(maxUlpObserved: 0),
            flags: [.truncated, .bimodal, .approximate],
            runID: "flags-1"
        )
        let doc = makeDocument(runID: "flags-1", cases: [c])
        let csv = CSVExporter.render(doc)
        let line = csv.split(separator: "\n").first(where: { !$0.hasPrefix("#") })!
        let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // Last column (index 13) = flags.
        #expect(cells.last == "approximate;bimodal;truncated",
                "flags must be sorted alphabetically; got \(cells.last ?? "(none)")")
    }

    @Test("RunStore.finalizeRun writes samples.csv alongside manifest.json")
    func storeFinalizeWritesCSV() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)

        let metadata = makeMetadata(runID: "store-csv-1")
        try store.beginRun(metadata: metadata)
        let dist = LatencyDistribution(samples: [100, 200, 300])
        let c = makeCase(id: makeID(n: 64), single: dist, amortized: nil, runID: "store-csv-1")
        try store.writeCase(c)
        _ = try store.finalizeRun(runID: metadata.runID)

        let csvPath = store.samplesCSVURL(for: metadata.runID)
        #expect(FileManager.default.fileExists(atPath: csvPath.path))
        let contents = try String(contentsOf: csvPath, encoding: .utf8)
        #expect(contents.contains("# schemaVersion: \(SchemaVersion.current.description)"))
        #expect(contents.contains("# runID: store-csv-1"))
        #expect(contents.contains(",single_shot,"))
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSVExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeID(n: Int) -> WorkloadID {
        let params = try! CanonicalParams([:], impl: .naive, op: .dot, shape: .vector(n: n))
        return WorkloadID(
            op: .dot, impl: .naive, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    private func makeCase(
        id: WorkloadID,
        single: LatencyDistribution?,
        amortized: AmortizedResult?,
        runID: String = "rows-1"
    ) -> CaseResult {
        CaseResult(
            id: id,
            singleShot: single,
            amortized: amortized,
            bandwidthGBPerSec: amortized != nil ? 4.2 : nil,
            gflops: amortized != nil ? 2.1 : nil,
            preSampleRSS: 0, postSampleRSS: 0,
            memoryTrace: [], thermalEvents: [],
            timerOverheadNanos: 41.6,
            verification: .verified(maxUlpObserved: 0),
            flags: [],
            runID: runID
        )
    }

    private func makeMetadata(runID: String) -> RunMetadata {
        RunMetadata(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            preset: .smoke,
            git: GitProvenance(sha: "abc1234", branch: "test", dirty: false),
            build: BuildProvenance.probe(),
            hardware: HardwareInventory.probe(),
            linkedLibraryVersions: [:],
            fpcrAtStart: 0,
            lowPowerModeEnabled: false,
            timerOverheadNanos: 41.6,
            harnessOverheadNanos: 5.0,
            seedTableVersion: SeedTable.version
        )
    }

    private func makeDocument(runID: String, cases: [CaseResult]) -> RunDocument {
        RunDocument(
            schemaVersion: .current,
            runMetadata: makeMetadata(runID: runID),
            cases: cases
        )
    }
}
