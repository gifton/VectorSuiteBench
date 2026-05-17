import SwiftUI

/// Signed-percentage cell with a polarity-aware directional glyph (`▼` /
/// `▲`) and color (green for good, red for bad). Used by the merged-delta
/// diff table (Phase 2.2 implementation; visual is locked now per design
/// doc §1.5/4).
///
/// **Polarity matters.** Latency is lower-is-better, so `−12 %` reads
/// green. Throughput is higher-is-better, so the same `−12 %` reads red.
/// Callers must pass the right `DeltaPolarity` for the column. The
/// `isGood` decision is split out as a pure function on `DeltaPolarity`
/// so it can be unit-tested without a SwiftUI runtime.
///
/// **Accessibility floor** (locked decision §1.5/6): the directional
/// glyph is *always* present, never hue-only. Color-blind paths see the
/// `▼` / `▲` even when the green/red is indistinguishable.
struct DeltaGlyph: View {
    let value: Value
    let polarity: DeltaPolarity

    enum Value {
        /// Percentage delta. `+12.4` renders as `▲ +12%`, `-3.0` as
        /// `▼ -3%`. The integer format matches the design doc; callers
        /// supplying floats lose precision deliberately — diffs are
        /// rounded at the cell.
        case percent(Double)
        /// Baseline is missing. Renders as `—` in `text.lo`. Per locked
        /// decision §1.5/4: missing baseline is muted, not styled like a
        /// real-but-zero delta.
        case absent
    }

    var body: some View {
        switch value {
        case .percent(let p):
            let good = polarity.isGood(delta: p)
            HStack(spacing: 2) {
                Text(p < 0 ? "▼" : (p > 0 ? "▲" : "·"))
                Text(String(format: "%+.0f%%", p))
            }
            .font(VSBFont.monoShaAxis)
            .foregroundStyle(p == 0 ? VSB.Text.lo : (good ? VSB.Status.pass : VSB.Status.fail))
        case .absent:
            Text("—")
                .vsbMonoSha()
        }
    }
}

/// Whether a positive delta is "good" or "bad" for the metric in question.
///
/// `lowerIsBetter` covers latency, error, and memory. `higherIsBetter`
/// covers throughput, bandwidth, GFLOP/s. Pure-function logic — no
/// SwiftUI dependency — so tests can validate every polarity / sign
/// combination without a render path.
enum DeltaPolarity: Hashable, Sendable {
    /// Latency, error, memory pressure — smaller is better.
    case lowerIsBetter
    /// Throughput, bandwidth, GFLOP/s — larger is better.
    case higherIsBetter

    /// Returns `true` when the delta improves the metric. Zero is never
    /// "good" — there's no improvement.
    func isGood(delta: Double) -> Bool {
        switch self {
        case .lowerIsBetter:  return delta < 0
        case .higherIsBetter: return delta > 0
        }
    }
}

#Preview("DeltaGlyph — both polarities") {
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 24) {
            Text("Latency (lower better)").vsbBody(color: VSB.Text.md)
            DeltaGlyph(value: .percent(-12), polarity: .lowerIsBetter)
            DeltaGlyph(value: .percent(+8),  polarity: .lowerIsBetter)
            DeltaGlyph(value: .percent(0),   polarity: .lowerIsBetter)
            DeltaGlyph(value: .absent,       polarity: .lowerIsBetter)
        }
        HStack(spacing: 24) {
            Text("Throughput (higher better)").vsbBody(color: VSB.Text.md)
            DeltaGlyph(value: .percent(-12), polarity: .higherIsBetter)
            DeltaGlyph(value: .percent(+8),  polarity: .higherIsBetter)
            DeltaGlyph(value: .percent(0),   polarity: .higherIsBetter)
            DeltaGlyph(value: .absent,       polarity: .higherIsBetter)
        }
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
