import Foundation

/// Pairs two runs' cases by `WorkloadID` and surfaces the deltas for the
/// diff UI. Refuses to diff across hardware fingerprints (§7 measurement-
/// integrity rule) — comparing M3-vs-M4 numbers is misleading and the
/// canonical fix is "don't do that."
public struct RunDiff: Sendable {
    /// The "before" run (typically older / baseline / main branch).
    public let a: RunDocument
    /// The "after" run (typically newer / feature branch).
    public let b: RunDocument

    /// Per-WorkloadID pairs. Order matches `RunDocument.cases` of `a` first,
    /// followed by cases present only in `b`.
    public let pairs: [Pair]

    public struct Pair: Sendable {
        public let id: WorkloadID
        /// `nil` when the case is missing from the corresponding run.
        public let a: CaseResult?
        public let b: CaseResult?

        public init(id: WorkloadID, a: CaseResult?, b: CaseResult?) {
            self.id = id
            self.a = a
            self.b = b
        }

        /// p50 single-shot of B vs A as a fractional delta: (b - a) / a.
        /// `nil` if either side lacks a single-shot p50.
        public var singleShotP50Delta: Double? {
            guard let aP50 = a?.singleShot?.p50,
                  let bP50 = b?.singleShot?.p50,
                  aP50 > 0 else { return nil }
            return (Double(bP50) - Double(aP50)) / Double(aP50)
        }

        /// p99 single-shot of B vs A as a fractional delta.
        public var singleShotP99Delta: Double? {
            guard let aP99 = a?.singleShot?.p99,
                  let bP99 = b?.singleShot?.p99,
                  aP99 > 0 else { return nil }
            return (Double(bP99) - Double(aP99)) / Double(aP99)
        }

        /// GFLOP/s of B vs A as a fractional delta.
        public var gflopsDelta: Double? {
            guard let aG = a?.gflops, let bG = b?.gflops, aG > 0 else { return nil }
            return (bG - aG) / aG
        }

        public var isMissingFromA: Bool { a == nil && b != nil }
        public var isMissingFromB: Bool { a != nil && b == nil }
        public var isComplete: Bool { a != nil && b != nil }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case fingerprintMismatch(aFingerprint: String, bFingerprint: String)

        public var description: String {
            switch self {
            case .fingerprintMismatch(let af, let bf):
                return "Refusing to diff runs from different hardware: '\(af)' vs '\(bf)'. " +
                    "Cross-machine diffs are misleading; re-run both on the same device."
            }
        }
    }

    /// Pair two runs by canonical `WorkloadID`. Throws if the runs were
    /// recorded on different hardware (fingerprint mismatch — §7).
    public static func compare(a: RunDocument, b: RunDocument) throws -> RunDiff {
        let aFingerprint = a.runMetadata.hardware.fingerprint
        let bFingerprint = b.runMetadata.hardware.fingerprint
        guard aFingerprint == bFingerprint else {
            throw Error.fingerprintMismatch(aFingerprint: aFingerprint, bFingerprint: bFingerprint)
        }

        let aByID = Dictionary(uniqueKeysWithValues: a.cases.map { ($0.id, $0) })
        let bByID = Dictionary(uniqueKeysWithValues: b.cases.map { ($0.id, $0) })

        var pairs: [Pair] = []
        var seen = Set<WorkloadID>()
        for caseA in a.cases {
            pairs.append(Pair(id: caseA.id, a: caseA, b: bByID[caseA.id]))
            seen.insert(caseA.id)
        }
        for caseB in b.cases where !seen.contains(caseB.id) {
            pairs.append(Pair(id: caseB.id, a: nil, b: caseB))
        }
        return RunDiff(a: a, b: b, pairs: pairs)
    }

    /// Markdown table summarizing the diff — the format that gets pasted into
    /// PR descriptions. One row per pair, with delta columns for p50, p99,
    /// and GFLOP/s. Cells render `—` when data is unavailable.
    public func markdownTable() -> String {
        var lines: [String] = [
            "| Op | Impl | Shape | p50 Δ | p99 Δ | GFLOP/s Δ | Status |",
            "|---|---|---|---:|---:|---:|---|"
        ]
        for pair in pairs {
            let op = pair.id.op.rawValue
            let impl = pair.id.impl.rawValue
            let shape = Self.shapeString(pair.id.shape)
            let p50 = Self.percentOrDash(pair.singleShotP50Delta)
            let p99 = Self.percentOrDash(pair.singleShotP99Delta)
            let gfl = Self.percentOrDash(pair.gflopsDelta)
            let status: String
            if pair.isMissingFromA { status = "B-only" }
            else if pair.isMissingFromB { status = "A-only" }
            else { status = "" }
            lines.append("| \(op) | \(impl) | \(shape) | \(p50) | \(p99) | \(gfl) | \(status) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func shapeString(_ shape: Shape) -> String {
        switch shape {
        case .vector(let n):           return "vec(\(n))"
        case .pairwise(let b, let n):  return "pair(\(b),\(n))"
        case .matrix(let b, let n):    return "mat(\(b),\(n))"
        }
    }

    private static func percentOrDash(_ value: Double?) -> String {
        guard let v = value else { return "—" }
        let pct = v * 100
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", pct))%"
    }
}
