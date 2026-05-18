import SwiftUI
import BenchKit

/// Click-to-expand popover surfacing the full hardware inventory behind the
/// 7-cell header's Hardware cell (locked decision §1.5/5).
///
/// The headline ("M3 Max · 14C / 30G") deliberately abbreviates so the
/// header row fits 7 cells across; this popover is where an engineer
/// triangulates a run by hardware. Two-column key-value table — labels
/// left-aligned in caption color, values right-aligned in mono so chip
/// names, core counts, and version strings stay scannable.
///
/// The popover is intentionally compact (≈ 320 × 220) — it sits next to
/// its trigger cell, not as a modal sheet. Click outside dismisses.
struct HardwareFingerprintPopover: View {
    let hardware: HardwareInventory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            grid
        }
        .padding(16)
        .frame(width: 320)
        .background(VSB.Surface.s1)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hardware").vsbCaption()
            Text(RunSummaryFormatters.hardwareHeadline(for: hardware))
                .vsbMonoNumber(color: VSB.Text.hi)
            Text("Fingerprint: \(hardware.fingerprint)")
                .vsbMonoSha()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(RunSummaryFormatters.hardwarePopoverFields(for: hardware), id: \.label) { field in
                row(label: field.label, value: field.value)
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .vsbCaption()
                .frame(width: 130, alignment: .leading)
            Text(value)
                .vsbMonoSha(color: VSB.Text.hi)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(VSB.Surface.hair),
            alignment: .top
        )
    }
}

#Preview("HardwareFingerprintPopover") {
    HardwareFingerprintPopover(
        hardware: HardwareInventory(
            chip: "Apple M3 Max",
            pCoreCount: 12,
            eCoreCount: 4,
            gpuCoreCount: 30,
            memoryGB: 36,
            osVersion: "26.2",
            xcodeBuild: "26B12",
            swiftVersion: "6.0+"
        )
    )
    .padding(24)
    .background(VSB.Surface.bg)
}
