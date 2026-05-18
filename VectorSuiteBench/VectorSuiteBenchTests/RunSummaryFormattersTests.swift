import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit

/// Pure-function tests for the 7 cell formatters that drive
/// `RunSummaryHeader`. All clocks / locales / calendars are pinned so
/// test outcomes don't drift across time zones or system settings.
@Suite("RunSummaryFormatters")
struct RunSummaryFormattersTests {

    // MARK: - Hardware cell

    @Test("Hardware headline strips the Apple prefix and shows total cores + GPU")
    func hardwareHeadline() {
        let hardware = makeHardware(chip: "Apple M3 Max", pCores: 12, eCores: 4, gpuCores: 30)
        let headline = RunSummaryFormatters.hardwareHeadline(for: hardware)
        #expect(headline == "M3 Max · 16C / 30G")
    }

    @Test("Hardware headline leaves non-Apple chip strings alone")
    func hardwareHeadlineUnknownChip() {
        let hardware = makeHardware(chip: "unknown", pCores: 0, eCores: 0, gpuCores: 0)
        let headline = RunSummaryFormatters.hardwareHeadline(for: hardware)
        #expect(headline == "unknown · 0C / 0G")
    }

    @Test("Hardware context shows full chip name + memory")
    func hardwareContext() {
        let hardware = makeHardware(chip: "Apple M3 Max", memoryGB: 36)
        #expect(RunSummaryFormatters.hardwareContext(for: hardware) == "Apple M3 Max · 36 GB")
    }

    @Test("Hardware popover fields are stable and ordered")
    func hardwarePopoverFields() {
        let hardware = makeHardware()
        let fields = RunSummaryFormatters.hardwarePopoverFields(for: hardware)
        let labels = fields.map(\.label)
        #expect(labels == [
            "Chip", "Performance cores", "Efficiency cores", "GPU cores",
            "Memory", "OS", "Xcode build", "Swift",
        ])
        // Spot-check a couple of values to guard against accidental
        // remapping (which would otherwise compile silently).
        #expect(fields.first(where: { $0.label == "Memory" })?.value == "36 GB")
        #expect(fields.first(where: { $0.label == "Swift" })?.value == "6.0+")
    }

    @Test("stripApplePrefix is a no-op on strings that don't start with 'Apple '")
    func stripPrefixNoOp() {
        #expect(RunSummaryFormatters.stripApplePrefix("Intel Core i7") == "Intel Core i7")
        #expect(RunSummaryFormatters.stripApplePrefix("") == "")
        // Lowercase 'apple' should NOT be stripped — chip strings are
        // capitalized; lowercase is suspicious.
        #expect(RunSummaryFormatters.stripApplePrefix("apple m3") == "apple m3")
    }

    // MARK: - Preset cell

    @Test("Preset value uppercases the label; context renders wall time")
    func presetCell() {
        let metadata = makeMetadata(preset: .smoke, wallTimeNanos: 323_000_000_000)
        #expect(RunSummaryFormatters.presetValue(for: metadata) == "SMOKE")
        #expect(RunSummaryFormatters.presetContext(for: metadata) == "5m 23s")
    }

    @Test("Preset context renders em-dash when wall time is nil (pre-1.2 run)")
    func presetContextNilWall() {
        let metadata = makeMetadata(preset: .standard, wallTimeNanos: nil)
        #expect(RunSummaryFormatters.presetContext(for: metadata) == "—")
    }

    // MARK: - Started cell

    @Test("Started value renders MMMd inside the current year")
    func startedValueSameYear() {
        let metadata = makeMetadata(timestamp: makeDate(year: 2026, month: 5, day: 17))
        let value = RunSummaryFormatters.startedValue(
            for: metadata,
            now: makeDate(year: 2026, month: 8, day: 1),
            calendar: gregorianUTC,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(value.contains("May"))
        #expect(value.contains("17"))
        #expect(!value.contains("2026"),
                Comment(rawValue: "same-year value must omit the year; got '\(value)'"))
    }

    @Test("Started value includes the year on cross-year runs")
    func startedValueCrossYear() {
        let metadata = makeMetadata(timestamp: makeDate(year: 2025, month: 12, day: 30))
        let value = RunSummaryFormatters.startedValue(
            for: metadata,
            now: makeDate(year: 2026, month: 5, day: 17),
            calendar: gregorianUTC,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(value.contains("2025"))
    }

    @Test("Started context includes time-of-day and a relative phrase")
    func startedContext() {
        let metadata = makeMetadata(timestamp: makeDate(year: 2026, month: 5, day: 17, hour: 14, minute: 32))
        let context = RunSummaryFormatters.startedContext(
            for: metadata,
            now: makeDate(year: 2026, month: 5, day: 17, hour: 18),
            calendar: gregorianUTC,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(context.contains("14:32"), Comment(rawValue: "expected time-of-day in '\(context)'"))
        // RelativeDateTimeFormatter under POSIX produces something like
        // "in 0 seconds" / "3 hours ago"; we just assert the separator
        // and a non-empty tail so we don't over-couple to the formatter's
        // exact phrasing.
        let parts = context.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(parts.count == 2, Comment(rawValue: "expected 'HH:MM · relative'; got '\(context)'"))
    }

    // MARK: - Build cell

    @Test("Build value reads as 'Swift X · -O'")
    func buildValue() {
        let metadata = makeMetadata(swiftVersion: "6.0+", optimizationLevel: "-O")
        #expect(RunSummaryFormatters.buildValue(for: metadata) == "Swift 6.0+ · -O")
    }

    @Test("Build context surfaces configuration + SDK + Xcode build")
    func buildContext() {
        let metadata = makeMetadata(
            buildConfiguration: "Release",
            sdkVersion: "macosx14.0",
            xcodeBuild: "26B12"
        )
        #expect(RunSummaryFormatters.buildContext(for: metadata) ==
                "Release · SDK macosx14.0 · Xcode 26B12")
    }

    // MARK: - Cases cell

    @Test("Cases value reads as 'N cases' on completion")
    func casesValueComplete() {
        let document = makeDocument(totalCases: 342, truncated: 0, failed: 0, thermal: 0)
        #expect(RunSummaryFormatters.casesValue(for: document) == "342 cases")
    }

    @Test("Cases value reads as 'completed/total' on truncation")
    func casesValueTruncated() {
        let document = makeDocument(totalCases: 600, truncated: 258, failed: 0, thermal: 0)
        // 600 total, 258 truncated → 342 completed.
        #expect(RunSummaryFormatters.casesValue(for: document) == "342/600")
    }

    @Test("Cases context counts failures + thermal events")
    func casesContext() {
        let document = makeDocument(totalCases: 342, truncated: 0, failed: 2, thermal: 4)
        #expect(RunSummaryFormatters.casesContext(for: document) == "2 failed · 4 ⚠")
    }

    // MARK: - Harness cell

    @Test("Harness value formats timer overhead with one decimal")
    func harnessValue() {
        let metadata = makeMetadata(timerOverheadNanos: 41.62)
        #expect(RunSummaryFormatters.harnessValue(for: metadata) == "41.6 ns")
    }

    @Test("Harness context renders 'floor X ns/op' when self-bench available")
    func harnessContextPopulated() {
        let metadata = makeMetadata(harnessOverheadNanos: 5.04)
        #expect(RunSummaryFormatters.harnessContext(for: metadata) == "floor 5.0 ns/op")
    }

    @Test("Harness context renders 'floor —' when self-bench produced nothing")
    func harnessContextMissing() {
        let metadata = makeMetadata(harnessOverheadNanos: nil)
        #expect(RunSummaryFormatters.harnessContext(for: metadata) == "floor —")
    }

    // MARK: - Schema cell

    @Test("Schema value matches the document's on-disk version")
    func schemaValue() {
        let document = makeDocument(schemaVersion: SchemaVersion(major: 1, minor: 2))
        #expect(RunSummaryFormatters.schemaValue(for: document) == "1.2")
    }

    @Test("Schema context renders seed-table version")
    func schemaContext() {
        let metadata = makeMetadata(seedTableVersion: 1)
        #expect(RunSummaryFormatters.schemaContext(for: metadata) == "seed table v1")
    }

    // MARK: - Fixtures

    private var gregorianUTC: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func makeDate(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(identifier: "UTC")
        return gregorianUTC.date(from: components)!
    }

    private func makeHardware(
        chip: String = "Apple M3 Max",
        pCores: Int = 12,
        eCores: Int = 4,
        gpuCores: Int = 30,
        memoryGB: Int = 36,
        osVersion: String = "26.2",
        xcodeBuild: String = "26B12",
        swiftVersion: String = "6.0+"
    ) -> HardwareInventory {
        HardwareInventory(
            chip: chip,
            pCoreCount: pCores,
            eCoreCount: eCores,
            gpuCoreCount: gpuCores,
            memoryGB: memoryGB,
            osVersion: osVersion,
            xcodeBuild: xcodeBuild,
            swiftVersion: swiftVersion
        )
    }

    private func makeMetadata(
        preset: RunPreset = .smoke,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        swiftVersion: String = "6.0+",
        optimizationLevel: String = "-O",
        buildConfiguration: String = "Release",
        sdkVersion: String = "macosx14.0",
        xcodeBuild: String = "26B12",
        timerOverheadNanos: Double = 41.6,
        harnessOverheadNanos: Double? = 5.0,
        seedTableVersion: Int = 1,
        wallTimeNanos: UInt64? = 5 * 60 * 1_000_000_000
    ) -> RunMetadata {
        RunMetadata(
            runID: "fixture",
            timestamp: timestamp,
            preset: preset,
            git: GitProvenance(sha: "abc1234", branch: "main", dirty: false),
            build: BuildProvenance(
                optimizationLevel: optimizationLevel,
                buildConfiguration: buildConfiguration,
                swiftCompilerFlags: [],
                sdkVersion: sdkVersion,
                xcodeVersion: "1640"
            ),
            hardware: HardwareInventory(
                chip: "Apple M3 Max",
                pCoreCount: 12, eCoreCount: 4, gpuCoreCount: 30,
                memoryGB: 36,
                osVersion: "26.2",
                xcodeBuild: xcodeBuild,
                swiftVersion: swiftVersion
            ),
            linkedLibraryVersions: [:],
            fpcrAtStart: 0,
            lowPowerModeEnabled: false,
            timerOverheadNanos: timerOverheadNanos,
            harnessOverheadNanos: harnessOverheadNanos,
            seedTableVersion: seedTableVersion,
            wallTimeNanos: wallTimeNanos
        )
    }

    private func makeDocument(
        totalCases: Int = 1,
        truncated: Int = 0,
        failed: Int = 0,
        thermal: Int = 0,
        schemaVersion: SchemaVersion = .current
    ) -> RunDocument {
        let cases: [CaseResult] = (0..<totalCases).map { idx in
            let isTruncated = idx < truncated
            let isFailed = idx < failed
            let hasThermal = idx < thermal
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
                runID: "fixture"
            )
        }
        return RunDocument(schemaVersion: schemaVersion, runMetadata: makeMetadata(), cases: cases)
    }
}
