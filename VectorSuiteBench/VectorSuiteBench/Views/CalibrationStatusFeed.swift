import SwiftUI

/// Terminal-style transcript view for the first-launch calibration flow
/// (design doc §07: "a terminal-style status feed (mono, text-md)").
///
/// Renders an append-only list of lines in `vsbMonoSha` styling on a
/// dark surface, auto-scrolling to the latest line so the user always
/// sees the current step. Used by `FirstLaunchView`; could be reused
/// later for any other progress-bearing flow that needs the same
/// "show me what step you're on" affordance.
struct CalibrationStatusFeed: View {
    let lines: [CalibrationStatus.TranscriptLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .vsbMonoSha(color: VSB.Text.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .background(VSB.Surface.s0)
            .overlay(
                RoundedRectangle(cornerRadius: VSB.Radius.card, style: .continuous)
                    .strokeBorder(VSB.Surface.hair, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: VSB.Radius.card, style: .continuous))
            .onChange(of: lines.count) { _, _ in
                guard let last = lines.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Calibration progress transcript"))
        }
    }
}

#Preview("CalibrationStatusFeed — populated") {
    CalibrationStatusFeed(lines: [
        .init(text: "Checking peaks cache for M3Max-14C-30G-36GB…"),
        .init(text: "No cached peaks — measuring this machine from scratch."),
        .init(text: "Measuring single-P-core FMA throughput…"),
        .init(text: "Peak compute: 384.2 GFLOPS (4321000 iterations in 102 ms)."),
        .init(text: "Measuring memory bandwidth (STREAM-triad, multi-thread)…"),
        .init(text: "Peak bandwidth: 312.5 GB/s (12 threads × 128 MiB arrays)."),
        .init(text: "Writing peaks to M3Max-14C-30G-36GB.json…"),
        .init(text: "Calibration complete."),
    ])
    .frame(width: 480, height: 200)
    .padding(40)
    .background(VSB.Surface.bg)
}

#Preview("CalibrationStatusFeed — empty") {
    CalibrationStatusFeed(lines: [])
        .frame(width: 480, height: 200)
        .padding(40)
        .background(VSB.Surface.bg)
}
