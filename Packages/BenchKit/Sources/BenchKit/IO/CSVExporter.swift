import Foundation

/// One-way CSV export of a `RunDocument`. The wire format is **write-only**
/// — JSON is the only round-trip representation. CSV exists so humans and
/// shell tools can eyeball or pipe a run without learning the JSON schema.
///
/// **Row shape**: one row per `(case, mode)`. A case with both `singleShot`
/// and `amortized` data produces two rows; a case with only one mode
/// produces one row. The `mode` column always disambiguates.
///
/// **Header**: three comment lines (`# schemaVersion: ...`, `# runID: ...`,
/// `# columns: ...`) precede the data. Comment-line prefix is `#` so
/// `pandas.read_csv(comment="#")` ignores them automatically.
///
/// **Empty cells**: missing bandwidth / GFLOPS render as `,,` (two adjacent
/// commas). The reader sees a literal empty string and can decide whether to
/// treat that as 0 or skip — we don't write a sentinel like `nan` because
/// `nan,nan` is harder to grep for and ambiguous with a real NaN measurement.
///
/// **Amortized percentiles**: the underlying `batchNanos.p50` is the
/// per-loop wall time. CSV reports the **per-op** value (median / K) so the
/// number is directly comparable to a single-shot percentile of the same op
/// — the loop-level number is meaningless without K-context.
public enum CSVExporter {

    /// Column manifest — frozen wire-names. Adding a column = additive schema
    /// change (bump `SchemaVersion.minor`); reordering or renaming = breaking
    /// schema change. The comment header in every file pins
    /// `schemaVersion` so a later reader knows which manifest applies.
    public static let columns: [String] = [
        "op",
        "impl",
        "implClass",
        "dtype",
        "shape",
        "params",
        "mode",
        "p50_ns",
        "p99_ns",
        "p999_ns",
        "gflops",
        "bandwidth_gb_s",
        "verified",
        "flags",
    ]

    public enum Mode: String {
        case singleShot = "single_shot"
        case amortized
    }

    /// Render the document to a CSV string. Pure function — does no I/O.
    public static func render(_ document: RunDocument) -> String {
        var out = ""
        out.reserveCapacity(2048 + document.cases.count * 256)
        out.append("# schemaVersion: \(document.schemaVersion.description)\n")
        out.append("# runID: \(document.runMetadata.runID)\n")
        out.append("# columns: \(columns.joined(separator: ","))\n")
        for c in document.cases {
            if let dist = c.singleShot, !dist.isEmpty {
                out.append(row(case: c, mode: .singleShot, perOpNanosFromDist: dist))
                out.append("\n")
            }
            if let amortized = c.amortized, !amortized.batchNanos.isEmpty {
                out.append(row(case: c, mode: .amortized, amortized: amortized))
                out.append("\n")
            }
        }
        return out
    }

    /// Write the rendered CSV to a URL with an atomic temp+rename. Caller
    /// (typically `RunStore.finalizeRun`) supplies the destination.
    public static func write(_ document: RunDocument, to url: URL) throws {
        let csv = render(document)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try csv.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    // MARK: - Row helpers

    private static func row(
        case c: CaseResult,
        mode: Mode,
        perOpNanosFromDist dist: LatencyDistribution
    ) -> String {
        // Single-shot: percentiles are already per-op.
        rowImpl(
            case: c,
            mode: mode,
            p50: dist.p50.map(Double.init),
            p99: dist.p99.map(Double.init),
            p999: dist.p999.map(Double.init)
        )
    }

    private static func row(
        case c: CaseResult,
        mode: Mode,
        amortized: AmortizedResult
    ) -> String {
        // Amortized: divide loop-level percentiles by K for per-op numbers.
        let K = Double(amortized.iterationsPerBatch)
        return rowImpl(
            case: c,
            mode: mode,
            p50: amortized.batchNanos.p50.map { Double($0) / K },
            p99: amortized.batchNanos.p99.map { Double($0) / K },
            p999: amortized.batchNanos.p999.map { Double($0) / K }
        )
    }

    private static func rowImpl(
        case c: CaseResult,
        mode: Mode,
        p50: Double?,
        p99: Double?,
        p999: Double?
    ) -> String {
        let id = c.id
        let cells: [String] = [
            id.op.rawValue,
            id.impl.rawValue,
            id.implClass.rawValue,
            id.dtype.rawValue,
            shapeCell(id.shape),
            paramsCell(id.params),
            mode.rawValue,
            formatNanos(p50),
            formatNanos(p99),
            formatNanos(p999),
            formatDouble(c.gflops),
            formatDouble(c.bandwidthGBPerSec),
            verifiedCell(c.verification),
            flagsCell(c.flags),
        ]
        return cells.joined(separator: ",")
    }

    private static func shapeCell(_ shape: Shape) -> String {
        switch shape {
        case .vector(let n):          return "vec(\(n))"
        case .pairwise(let b, let n): return "pair(\(b);\(n))"
        case .matrix(let b, let n):   return "mat(\(b);\(n))"
        }
    }

    /// `params` cell uses `;`-separated entries so the comma stays as the
    /// CSV column separator. Empty params render as `{}` so the cell is
    /// non-empty (easier to grep for in shell pipelines).
    private static func paramsCell(_ params: CanonicalParams) -> String {
        if params.isEmpty { return "{}" }
        let entries = params.keys.map { "\($0):\(params[$0] ?? "")" }
        return entries.joined(separator: ";")
    }

    private static func verifiedCell(_ result: VerificationResult) -> String {
        switch result {
        case .verified:     return "true"
        case .unverifiable: return "unverifiable"
        case .failed:       return "false"
        }
    }

    private static func flagsCell(_ flags: Set<CaseFlag>) -> String {
        // Sorted for stable diffs across runs of the same workload.
        flags.map(\.rawValue).sorted().joined(separator: ";")
    }

    /// Format a nanosecond percentile. `nil` → empty cell. Integer output
    /// when the value is a whole number; one decimal otherwise (helps with
    /// per-op amortized numbers like `7.4 ns`).
    private static func formatNanos(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded() {
            return String(Int64(value))
        }
        return String(format: "%.1f", value)
    }

    private static func formatDouble(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.4f", value)
    }
}
