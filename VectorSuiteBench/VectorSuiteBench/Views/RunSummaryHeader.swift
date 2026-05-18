import SwiftUI
import BenchKit

/// 7-cell info-grid spanning the top of `RunDetailView` (design doc §04
/// "Run Summary header"):
///
/// ```
/// ┌─────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
/// │ PRESET  │ STARTED  │ HARDWARE │ BUILD    │ CASES    │ HARNESS  │ SCHEMA   │
/// │ SMOKE   │ May 17   │ M3 Max … │ Swift 6+ │ 342 cases│ 41.6 ns  │ 1.2      │
/// │ 5m 23s  │ 14:32 …  │ M3 Max…  │ -O · …   │ 0 failed │ floor 5…│ seed v1  │
/// └─────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
/// ```
///
/// Each cell is three lines: caption / value / context. Cell borders are
/// 1 px hair lines so the row reads as one structure, not seven cards.
///
/// **Thermal banner.** When `cases.contains { !$0.thermalEvents.isEmpty }`
/// (i.e. the OS reported a thermal escalation during *any* case), a
/// warn-tinted banner renders above the grid. Per design doc §07, this
/// is **non-dismissable** — the signal is too important to be a tooltip.
///
/// **Hardware popover.** Per locked decision §1.5/5, the Hardware cell
/// is clickable and presents an `NSPopover`-equivalent (SwiftUI's
/// `.popover(...)` modifier) carrying the full chip details.
struct RunSummaryHeader: View {
    let document: RunDocument
    let now: Date

    @State private var hardwarePopoverPresented = false

    init(document: RunDocument, now: Date = Date()) {
        self.document = document
        self.now = now
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasThermalEvents {
                ThermalBanner(eventCount: thermalEventCount)
            }
            grid
        }
    }

    // MARK: - Derived

    private var hasThermalEvents: Bool { thermalEventCount > 0 }

    private var thermalEventCount: Int {
        document.cases.reduce(0) { $0 + $1.thermalEvents.count }
    }

    private var metadata: RunMetadata { document.runMetadata }

    // MARK: - Grid

    private var grid: some View {
        HStack(spacing: 0) {
            cell(label: "Preset",
                 value: RunSummaryFormatters.presetValue(for: metadata),
                 context: RunSummaryFormatters.presetContext(for: metadata))

            divider
            cell(label: "Started",
                 value: RunSummaryFormatters.startedValue(for: metadata, now: now),
                 context: RunSummaryFormatters.startedContext(for: metadata, now: now))

            divider
            hardwareCell

            divider
            cell(label: "Build",
                 value: RunSummaryFormatters.buildValue(for: metadata),
                 context: RunSummaryFormatters.buildContext(for: metadata))

            divider
            cell(label: "Cases",
                 value: RunSummaryFormatters.casesValue(for: document),
                 context: RunSummaryFormatters.casesContext(for: document))

            divider
            cell(label: "Harness",
                 value: RunSummaryFormatters.harnessValue(for: metadata),
                 context: RunSummaryFormatters.harnessContext(for: metadata))

            divider
            cell(label: "Schema",
                 value: RunSummaryFormatters.schemaValue(for: document),
                 context: RunSummaryFormatters.schemaContext(for: metadata))
        }
        .overlay(
            Rectangle()
                .strokeBorder(VSB.Surface.hair, lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(VSB.Surface.hair)
            .frame(width: 1)
    }

    private func cell(label: String, value: String, context: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).vsbCaption()
            Text(value)
                .vsbMonoNumber(color: VSB.Text.hi)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(context)
                .vsbMonoSha()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hardware cell (popover)

    /// Same three-line shape as the other cells, but wrapped in a button
    /// that toggles the hardware-detail popover. The cursor flips to a
    /// pointing-hand on hover so the affordance is discoverable without
    /// the button looking like a button (which would compete visually
    /// with the data).
    private var hardwareCell: some View {
        Button {
            hardwarePopoverPresented.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hardware").vsbCaption()
                HStack(spacing: 4) {
                    Text(RunSummaryFormatters.hardwareHeadline(for: metadata.hardware))
                        .vsbMonoNumber(color: VSB.Text.hi)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(VSB.Text.lo)
                }
                Text(RunSummaryFormatters.hardwareContext(for: metadata.hardware))
                    .vsbMonoSha()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $hardwarePopoverPresented, arrowEdge: .bottom) {
            HardwareFingerprintPopover(hardware: metadata.hardware)
        }
        .accessibilityLabel(Text("Hardware details, click for full chip information"))
    }
}

// MARK: - Thermal banner

/// Warn-tinted banner that sits above the 7-cell grid when the OS reported
/// thermal throttling during any case. Non-dismissable (design doc §07
/// rationale: the signal is too important to be a tooltip).
private struct ThermalBanner: View {
    let eventCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "thermometer.high")
                .foregroundStyle(VSB.Status.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Thermal throttle during run").vsbBody(color: VSB.Status.warn)
                Text(message)
                    .vsbMonoSha(color: VSB.Text.md)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VSB.Status.warn.opacity(0.10))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(VSB.Status.warn.opacity(0.33)),
            alignment: .bottom
        )
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        let suffix = eventCount == 1 ? "event" : "events"
        return "\(eventCount) thermal \(suffix) observed — cases run during throttling may not reflect peak performance."
    }
}

// MARK: - Preview

#Preview("RunSummaryHeader — clean run") {
    RunSummaryHeader(document: previewDocument(thermalEvents: 0, failed: 0), now: previewNow)
        .frame(width: 900)
        .padding(16)
        .background(VSB.Surface.bg)
}

#Preview("RunSummaryHeader — thermal + failures") {
    RunSummaryHeader(
        document: previewDocument(thermalEvents: 4, failed: 2, truncated: 12),
        now: previewNow
    )
    .frame(width: 900)
    .padding(16)
    .background(VSB.Surface.bg)
}

// MARK: - Preview fixtures (private)

private let previewNow: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 5; c.day = 17; c.hour = 18; c.minute = 0
    c.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: c)!
}()

private func previewDocument(
    thermalEvents: Int,
    failed: Int,
    truncated: Int = 0,
    totalCases: Int = 342
) -> RunDocument {
    let metadata = RunMetadata(
        runID: "preview-run",
        timestamp: previewNow.addingTimeInterval(-3 * 3600 - 200),
        preset: .smoke,
        git: GitProvenance(sha: "abc1234", branch: "main", dirty: false),
        build: BuildProvenance(
            optimizationLevel: "-O",
            buildConfiguration: "Release",
            swiftCompilerFlags: [],
            sdkVersion: "macosx14.0",
            xcodeVersion: "1640"
        ),
        hardware: HardwareInventory(
            chip: "Apple M3 Max",
            pCoreCount: 12,
            eCoreCount: 4,
            gpuCoreCount: 30,
            memoryGB: 36,
            osVersion: "26.2",
            xcodeBuild: "26B12",
            swiftVersion: "6.0+"
        ),
        linkedLibraryVersions: ["BenchKit": "0.2.0"],
        fpcrAtStart: 0x01,
        lowPowerModeEnabled: false,
        timerOverheadNanos: 41.6,
        harnessOverheadNanos: 5.2,
        seedTableVersion: 1,
        wallTimeNanos: 5 * 60 * 1_000_000_000 + 23 * 1_000_000_000
    )
    let cases: [CaseResult] = (0..<totalCases).map { idx in
        let isFailed = idx < failed
        let isTruncated = idx < truncated
        let hasThermal = idx < thermalEvents
        let id = WorkloadID(
            op: .dot, impl: .naive, implClass: .standard,
            dtype: .f32, shape: .vector(n: 64),
            params: try! CanonicalParams([:], impl: .naive, op: .dot, shape: .vector(n: 64))
        )
        return CaseResult(
            id: id,
            singleShot: nil,
            amortized: nil,
            bandwidthGBPerSec: nil,
            gflops: nil,
            preSampleRSS: 0,
            postSampleRSS: 0,
            memoryTrace: [],
            thermalEvents: hasThermal
                ? [ThermalEvent(timestampNanos: 0, from: "nominal", to: "serious")]
                : [],
            timerOverheadNanos: 41.6,
            verification: isFailed
                ? .failed(maxUlpObserved: 2048, window: 1024, sampleIndex: 0)
                : .verified(maxUlpObserved: 2),
            flags: isTruncated ? [.truncated] : [],
            runID: "preview-run"
        )
    }
    return RunDocument(schemaVersion: .current, runMetadata: metadata, cases: cases)
}
