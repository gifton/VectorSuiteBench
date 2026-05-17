import SwiftUI

/// Right-aligned number cell — the atom that fills every numeric column
/// of the data table and every value field of the summary header.
///
/// **Three states** map directly to the design doc's row treatments:
/// - `.value(_)` — normal cell, mono tabular at `text.hi` (or accent for
///   VectorCore rows per design principle P-02).
/// - `.missing` — `—` at `text.lo`. Used when a derived field is nil
///   (e.g., `bandwidthGBPerSec` on a single-shot-only case) or when a
///   diff has no baseline.
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
    var format: String = "%.0f"
    var unit: String? = nil
    var isAccent: Bool = false

    enum State {
        case value(Double)
        case missing
        case error
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Spacer(minLength: 0)
            switch state {
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
                    .font(VSBFont.monoBadge)
                    .tracking(0.4)
                    .foregroundStyle(VSB.Status.fail)
            }
        }
    }
}

#Preview("NumberCell — value, accent, missing, error") {
    VStack(alignment: .trailing, spacing: 6) {
        Group {
            NumberCell(state: .value(118), unit: "ns")
            NumberCell(state: .value(118), unit: "ns", isAccent: true)
            NumberCell(state: .value(26.04), format: "%.2f", unit: "GFLOP/s")
            NumberCell(state: .missing)
            NumberCell(state: .error)
        }
        .frame(width: 120)
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
