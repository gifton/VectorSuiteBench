import SwiftUI

/// Right-aligned number cell — the atom that fills every numeric column
/// of the data table and every value field of the summary header.
///
/// **Three states** map directly to the design doc's row treatments:
/// - `.value(_)` — normal cell, mono tabular at `text.hi` (or accent for
///   VectorCore rows per design principle P-02). NaN / Inf are sanitized
///   to `.missing` (see `sanitize(_:)`).
/// - `.missing` — `—` at `text.lo`. Used when a derived field is nil
///   (e.g., `bandwidthGBPerSec` on a single-shot-only case), when a diff
///   has no baseline, or when chart-data arithmetic produced a non-finite
///   value.
/// - `.error` — `ERR` in `--fail`. Used when verification failed; the
///   row's perf cells all redact so a faster-but-wrong impl is never
///   read as "winning".
///
/// The unit suffix (`ns`, `GB/s`, `GFLOP/s`) is optional and renders at
/// `text.lo` in the smaller `monoShaAxis` font — present in summary
/// cards, suppressed in dense table cells where the column header
/// already carries the unit.
struct NumberCell: View {
    let state: State
    let format: String
    let unit: String?
    let isAccent: Bool

    init(
        state: State,
        format: String = "%.0f",
        unit: String? = nil,
        isAccent: Bool = false
    ) {
        self.state = state
        self.format = format
        self.unit = unit
        self.isAccent = isAccent
    }

    enum State: Equatable, Sendable {
        case value(Double)
        case missing
        case error
    }

    /// Sanitize a state for display. NaN / Inf collapse to `.missing` — a
    /// raw `String(format: "%.0f", .nan)` produces `"nan"` in mono-number
    /// style at `text.hi`, which is indistinguishable from a real value.
    /// Split out as a pure function so it's unit-testable.
    static func sanitize(_ state: State) -> State {
        if case .value(let v) = state, !v.isFinite {
            return .missing
        }
        return state
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Spacer(minLength: 0)
            switch Self.sanitize(state) {
            case .value(let v):
                Text(String(format: format, v))
                    .vsbMonoNumber(color: isAccent ? VSB.Impl.vectorCore : VSB.Text.hi)
                if let unit {
                    Text(unit)
                        .vsbMonoSha()
                }
            case .missing:
                Text("—")
                    .vsbMonoNumber(color: VSB.Text.lo)
            case .error:
                Text("ERR")
                    .vsbMonoBadge(color: VSB.Status.fail)
            }
        }
    }
}

#Preview("NumberCell — value, accent, missing, error, NaN") {
    VStack(alignment: .trailing, spacing: 6) {
        Group {
            NumberCell(state: .value(118), unit: "ns")
            NumberCell(state: .value(118), unit: "ns", isAccent: true)
            NumberCell(state: .value(26.04), format: "%.2f", unit: "GFLOP/s")
            NumberCell(state: .missing)
            NumberCell(state: .error)
            NumberCell(state: .value(.nan), unit: "ns")          // → "—"
            NumberCell(state: .value(.infinity), unit: "ns")     // → "—"
        }
        .frame(width: 120)
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
