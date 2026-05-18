import Foundation
import BenchKit

/// Pure-function formatters for the 7 cells of `RunSummaryHeader` (design
/// doc §04). Lives next to the view but SwiftUI-free so the formatters are
/// unit-testable without view inspection — the same pattern as
/// `RunSummaryGrouping` for the sidebar.
///
/// **Cell taxonomy** (left → right across the header):
///
/// 1. **Preset**   — preset label + wall time.
/// 2. **Started**  — short date + relative-to-now context.
/// 3. **Hardware** — fingerprint headline (clickable → popover with full chip details).
/// 4. **Build**    — Swift version + optimization level.
/// 5. **Cases**    — completed/total + thermal escalations + verification failures.
/// 6. **Harness**  — timer overhead + harness floor (NullWorkload self-bench).
/// 7. **Schema**   — schema version + seed-table version.
///
/// Every cell renders as three lines:
/// - **Label** (caption, lo color)
/// - **Value** (mono number, hi color — the load-bearing reading)
/// - **Context** (mono SHA-style, lo color — supporting detail)
///
/// The functions below return the `value` / `context` strings; the view
/// owns the labels (they're sacred enough to live next to layout).
///
/// `now` and `locale` / `calendar` are explicit parameters where they
/// matter so tests pin them. Production callers default to `.current`
/// everywhere — the header re-renders on coordinator changes so live
/// re-evaluation happens for free.
nonisolated enum RunSummaryFormatters {

    // MARK: - Preset cell

    /// `"SMOKE"` / `"STANDARD"` / `"FULL"` / `"CUSTOM"`. Uppercased.
    static func presetValue(for metadata: RunMetadata) -> String {
        metadata.preset.label.uppercased()
    }

    /// `"5m 23s"` (re-uses the sidebar's duration formatter) — or `"—"`
    /// for pre-1.2 runs without a wall-time stamp.
    static func presetContext(for metadata: RunMetadata) -> String {
        RunSummaryGrouping.formatDuration(nanos: metadata.wallTimeNanos)
    }

    // MARK: - Started cell

    /// Short calendar date — `"May 17"` / `"Dec 30 2025"`. Year-suffixed
    /// across year boundaries (same shape as the sidebar's older-day
    /// section headers).
    static func startedValue(
        for metadata: RunMetadata,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let nowYear = calendar.component(.year, from: now)
        let runYear = calendar.component(.year, from: metadata.timestamp)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(
            runYear == nowYear ? "MMMd" : "MMMdyyyy"
        )
        return formatter.string(from: metadata.timestamp)
    }

    /// Relative-time context: `"14:32 · 3 hours ago"`. Time-of-day from
    /// `formatTimeOfDay`; relative phrase from a `RelativeDateTimeFormatter`
    /// so we get "just now" / "2 minutes ago" / "yesterday" / etc.
    static func startedContext(
        for metadata: RunMetadata,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = RunSummaryGrouping.formatTimeOfDay(
            metadata.timestamp,
            calendar: calendar,
            locale: locale
        )
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.calendar = calendar
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        let relative = relativeFormatter.localizedString(for: metadata.timestamp, relativeTo: now)
        return "\(time) · \(relative)"
    }

    // MARK: - Hardware cell

    /// Headline string for the hardware cell. `"M3 Max · 14C / 30G"`:
    /// chip identifier (minus the noisy `"Apple "` prefix) + total CPU
    /// cores + GPU cores. Tight enough to fit a one-line cell at 120 px.
    static func hardwareHeadline(for hardware: HardwareInventory) -> String {
        let chipName = stripApplePrefix(hardware.chip)
        let totalCores = hardware.pCoreCount + hardware.eCoreCount
        return "\(chipName) · \(totalCores)C / \(hardware.gpuCoreCount)G"
    }

    /// Short context line: `"Apple M3 Max · 36 GB"` — the full chip
    /// identifier plus memory, anchoring what the headline abbreviates.
    static func hardwareContext(for hardware: HardwareInventory) -> String {
        "\(hardware.chip) · \(hardware.memoryGB) GB"
    }

    /// Ordered label/value pairs surfaced in the click-to-expand popover.
    /// Hand-rolled list (not Mirror reflection) so each row's label is
    /// curated and the order is deterministic.
    static func hardwarePopoverFields(for hardware: HardwareInventory) -> [(label: String, value: String)] {
        [
            ("Chip", hardware.chip),
            ("Performance cores", "\(hardware.pCoreCount)"),
            ("Efficiency cores", "\(hardware.eCoreCount)"),
            ("GPU cores", "\(hardware.gpuCoreCount)"),
            ("Memory", "\(hardware.memoryGB) GB"),
            ("OS", hardware.osVersion),
            ("Xcode build", hardware.xcodeBuild),
            ("Swift", hardware.swiftVersion),
        ]
    }

    /// Strip the `"Apple "` prefix from chip identifiers so the headline
    /// fits a narrow cell. `"Apple M3 Max"` → `"M3 Max"`. Leaves
    /// non-Apple strings (e.g. "unknown") alone.
    static func stripApplePrefix(_ chip: String) -> String {
        if chip.hasPrefix("Apple "),
           let range = chip.range(of: "Apple ") {
            return String(chip[range.upperBound...])
        }
        return chip
    }

    // MARK: - Build cell

    /// `"Swift 6.0+ · -O"` — Swift compiler version (from HardwareInventory,
    /// where it's a compile-time bake-in) + optimization level (from
    /// BuildProvenance). The pair the perf engineer needs to triage a
    /// run is "what Swift / what -O level"; everything else is context.
    static func buildValue(for metadata: RunMetadata) -> String {
        "Swift \(metadata.hardware.swiftVersion) · \(metadata.build.optimizationLevel)"
    }

    /// `"Release · SDK 14.0 · Xcode 26B12"` — the surrounding chrome.
    static func buildContext(for metadata: RunMetadata) -> String {
        "\(metadata.build.buildConfiguration) · SDK \(metadata.build.sdkVersion) · Xcode \(metadata.hardware.xcodeBuild)"
    }

    // MARK: - Cases cell

    /// `"342 cases"` for fully-completed runs; `"342/600"` when truncated.
    /// Re-uses the sidebar's formatter to keep the two views consistent.
    static func casesValue(for document: RunDocument) -> String {
        let total = document.runMetadata.preset.totalCount ?? document.cases.count
        let completed = document.cases.filter { !$0.flags.contains(.truncated) }.count
        return RunSummaryGrouping.formatCaseCount(completed: completed, total: total)
    }

    /// `"0 failed · 0 ⚠"` on a clean run; tightens on incident — design doc
    /// §07: `"342/342 · 0 failed · 4 ⚠"`. The leading count is already in
    /// the value line above; this context surfaces failures and thermal
    /// events without duplicating the total.
    static func casesContext(for document: RunDocument) -> String {
        let failed = document.cases.filter { $0.verification.isFailure }.count
        let thermal = document.cases.reduce(0) { $0 + $1.thermalEvents.count }
        return "\(failed) failed · \(thermal) ⚠"
    }

    // MARK: - Harness cell

    /// `"41.6 ns"` — `mach_absolute_time` overhead median (metadata only,
    /// never subtracted from single-shot samples — spec §2.3).
    static func harnessValue(for metadata: RunMetadata) -> String {
        formatNanos(metadata.timerOverheadNanos)
    }

    /// `"floor 5.0 ns/op"` when the NullWorkload self-bench produced a
    /// floor; `"floor —"` otherwise (rare; only happens when the
    /// self-bench was budget-constrained out of producing an amortized
    /// number). The floor is what an empty `invoke` costs — the
    /// baseline below which no real workload can read.
    static func harnessContext(for metadata: RunMetadata) -> String {
        guard let floor = metadata.harnessOverheadNanos else {
            return "floor —"
        }
        return "floor \(formatNanos(floor))/op"
    }

    /// Format a nanosecond Double with one decimal place. `41.6 ns`.
    static func formatNanos(_ value: Double) -> String {
        String(format: "%.1f ns", value)
    }

    // MARK: - Schema cell

    /// `"1.2"` — the on-disk schema version. Knowing this is load-bearing
    /// when looking at an older run that may not carry newer optional fields.
    static func schemaValue(for document: RunDocument) -> String {
        "\(document.schemaVersion)"
    }

    /// `"seed table v1"` — the SeedTable.version baked into the run.
    /// A bump here means input bytes are no longer comparable to prior
    /// runs (the seed → bytes function changed).
    static func schemaContext(for metadata: RunMetadata) -> String {
        "seed table v\(metadata.seedTableVersion)"
    }
}

// MARK: - VerificationResult convenience

extension VerificationResult {
    /// `true` only for the `.failed` case. `.unverifiable` is informational,
    /// not a failure. `nonisolated` so it's callable from
    /// `RunSummaryFormatters` (which is itself nonisolated).
    fileprivate nonisolated var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - RunPreset convenience

extension RunPreset {
    /// Total case count baked into the preset, when available. `.smoke`
    /// and `.standard` / `.full` have fixed counts decided by the
    /// registry; `.custom` carries an explicit `[WorkloadID]` whose count
    /// is what `count` returns.
    ///
    /// `nil` for `.smoke`/`.standard`/`.full` because the **filter** they
    /// represent is registry-dependent (the registry isn't visible to a
    /// loaded RunDocument). For those, callers should fall back to
    /// `document.cases.count`. `nonisolated` so it's callable from
    /// `RunSummaryFormatters` (which is itself nonisolated).
    fileprivate nonisolated var totalCount: Int? {
        if case .custom(_, _, let ids) = self {
            return ids.count
        }
        return nil
    }
}
