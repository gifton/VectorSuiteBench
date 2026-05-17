import SwiftUI
import BenchKit

/// First-launch / hardware-calibration empty state. Replaces the normal
/// detail pane when no usable `peaks/<fingerprint>.json` record exists
/// (design doc §07 "Empty state · first launch"):
///
///   1. Centered `cpu.mac` hero icon.
///   2. "Hardware Calibration Required" heading.
///   3. Primary `⌖ Measure Peaks (~30s)` button — drives `CalibrationStatus.start`.
///   4. While running: small circular spinner above a terminal-style
///      transcript feed.
///   5. On failure: error banner + Retry button.
///   6. On success: AppRoot swaps this view out for the normal detail
///      pane (the .complete state never visibly renders for more than
///      one frame).
///
/// Re-prompt rules (per plan §2 / Item 5): the host (AppRoot) decides
/// when to show this view based on `RunStoreCoordinator.peaksExist(for:)`,
/// which routes through `PeakMeasurement.loadCached` and treats
/// stale-method cache hits as no-cache. So a hardware change or a
/// method-version bump automatically re-shows this empty state.
struct FirstLaunchView: View {
    let hardware: HardwareInventory
    let store: RunStore

    @Bindable var calibration: CalibrationStatus

    var body: some View {
        VStack(spacing: 24) {
            hero
            content
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSB.Surface.bg)
    }

    // MARK: - Pieces

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu.mac")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(VSB.Text.md)
                .accessibilityHidden(true)

            Text("Hardware Calibration Required").vsbTitle()

            Text("Before any chart can render meaningfully, VectorSuiteBench needs to measure what your machine is actually capable of — peak single-core FLOPS and peak memory bandwidth.")
                .vsbBody(color: VSB.Text.md)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch calibration.phase {
        case .idle:
            Button {
                calibration.start(hardware: hardware, store: store)
            } label: {
                Pill("MEASURE PEAKS (~30s)", style: .accent, systemImage: "scope")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Measure hardware peaks, takes about thirty seconds"))

        case .running:
            runningOrCompleteContent(showSpinner: true)

        case .complete:
            // Visible for at most one frame before AppRoot re-evaluates
            // `peaksExist` and swaps to the detail pane. Render the final
            // feed state so the transition reads as "done, then move on"
            // rather than a flash of unrelated content.
            runningOrCompleteContent(showSpinner: false)

        case .failed(let message):
            failedContent(message: message)
        }
    }

    private func runningOrCompleteContent(showSpinner: Bool) -> some View {
        VStack(spacing: 12) {
            if showSpinner {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Calibration in progress"))
            }
            CalibrationStatusFeed(lines: calibration.transcript)
                .frame(maxWidth: 480, maxHeight: 200)
        }
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: 12) {
            Pill("FAILED", style: .fail, icon: "✕")
            Text(message)
                .vsbBody(color: VSB.Text.md)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            CalibrationStatusFeed(lines: calibration.transcript)
                .frame(maxWidth: 480, maxHeight: 160)
            Button {
                calibration.reset()
                calibration.start(hardware: hardware, store: store)
            } label: {
                Pill("RETRY", style: .neutral, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview("FirstLaunchView — idle") {
    FirstLaunchView(
        hardware: HardwareInventory.probe(),
        store: previewStore(),
        calibration: CalibrationStatus()
    )
    .frame(width: 900, height: 700)
}

#Preview("FirstLaunchView — running (stub measure)") {
    let calibration = CalibrationStatus(measure: stubMeasure(
        kind: .completes(after: .seconds(60))
    ))
    let view = FirstLaunchView(
        hardware: HardwareInventory.probe(),
        store: previewStore(),
        calibration: calibration
    )
    .frame(width: 900, height: 700)
    .task {
        calibration.start(hardware: HardwareInventory.probe(), store: previewStore())
    }
    return view
}

// MARK: - Preview fixtures (private)

private func previewStore() -> RunStore {
    RunStore(rootURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("FirstLaunchViewPreview-\(UUID().uuidString)"))
}

private enum StubKind {
    case completes(after: Duration)
    case fails(after: Duration, message: String)
}

private func stubMeasure(kind: StubKind) -> CalibrationStatus.Measure {
    return { hardware, _, emit in
        emit("Checking peaks cache for \(hardware.fingerprint)…")
        emit("No cached peaks — running stubbed measurement (preview only).")
        emit("Measuring single-P-core FMA throughput…")
        switch kind {
        case .completes(let delay):
            try await Task.sleep(for: delay / 4)
            emit("Peak compute: 384.2 GFLOPS (fake).")
            emit("Measuring memory bandwidth (STREAM-triad)…")
            try await Task.sleep(for: delay / 2)
            emit("Peak bandwidth: 312.5 GB/s (fake).")
            emit("Calibration complete.")
            return PeakRecord(
                schemaVersion: .current,
                hardwareFingerprint: hardware.fingerprint,
                measuredAt: Date(),
                peakComputeGFLOPS: 384.2,
                peakBandwidthGBPerSec: 312.5,
                method: PeakMethod(compute: "stub", bandwidth: "stub")
            )
        case .fails(let delay, let message):
            try await Task.sleep(for: delay / 2)
            emit("Stage failed.")
            struct StubError: LocalizedError {
                let message: String
                var errorDescription: String? { message }
            }
            throw StubError(message: message)
        }
    }
}
