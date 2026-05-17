import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit

/// Pure-function tests for the sidebar's date-grouping + cell-formatting
/// logic. Date math runs against an explicit `now` and a fixed Gregorian
/// calendar so test outcomes don't drift across time zones / locales.
@Suite("RunSummaryGrouping")
struct RunSummaryGroupingTests {

    // MARK: - Section bucketing

    @Test("Empty input produces empty buckets")
    func emptyInput() {
        let buckets = RunSummaryGrouping.group([], now: anchor)
        #expect(buckets.isEmpty)
    }

    @Test("Today / Yesterday / older-day bucketing")
    func basicBucketing() {
        let summaries = [
            makeSummary(id: "t1", at: anchor.adding(hours: -1)),
            makeSummary(id: "t2", at: anchor.adding(hours: -3)),
            makeSummary(id: "y1", at: anchor.adding(days: -1)),
            makeSummary(id: "old", at: anchor.adding(days: -4)),
        ]
        let buckets = RunSummaryGrouping.group(summaries, now: anchor, calendar: gregorianUTC)
        #expect(buckets.count == 3)
        #expect(buckets[0].section == .today)
        #expect(buckets[0].summaries.map(\.runID) == ["t1", "t2"])
        #expect(buckets[1].section == .yesterday)
        #expect(buckets[1].summaries.map(\.runID) == ["y1"])
        if case .day = buckets[2].section { /* ok */ } else {
            Issue.record(Comment(rawValue: "expected .day(...) bucket; got \(buckets[2].section)"))
        }
        #expect(buckets[2].summaries.map(\.runID) == ["old"])
    }

    @Test("Within-section ordering is newest-first")
    func withinSectionOrdering() {
        // Intentionally feed oldest-first; group() must re-sort.
        let summaries = [
            makeSummary(id: "a", at: anchor.adding(hours: -5)),
            makeSummary(id: "b", at: anchor.adding(hours: -2)),
            makeSummary(id: "c", at: anchor.adding(hours: -1)),
        ]
        let buckets = RunSummaryGrouping.group(summaries, now: anchor, calendar: gregorianUTC)
        #expect(buckets.count == 1)
        #expect(buckets[0].section == .today)
        #expect(buckets[0].summaries.map(\.runID) == ["c", "b", "a"])
    }

    @Test("Two-days-back runs do NOT collapse into Yesterday")
    func twoDaysBackNotYesterday() {
        // Anchor: 2026-05-17 14:00 UTC. A run timestamped at 23:59 the day
        // *before yesterday* lives in its own .day(...) bucket, not in
        // "Yesterday" — yesterday is strictly the 24-hour calendar day
        // immediately before today.
        let twoDaysBack = anchor.adding(days: -2).adding(hours: 9, minutes: 59)
        let buckets = RunSummaryGrouping.group(
            [makeSummary(id: "edge", at: twoDaysBack)],
            now: anchor,
            calendar: gregorianUTC
        )
        #expect(buckets.count == 1)
        if case .day = buckets[0].section { /* ok */ } else {
            Issue.record(Comment(rawValue: "expected .day(...) for two-days-back run; got \(buckets[0].section)"))
        }
    }

    @Test("Shuffled cross-section input lands in the right buckets, newest-first")
    func crossSectionShuffle() {
        // Interleave Today / Yesterday / older inputs in adversarial order
        // so `group(...)` is forced to both bucket and re-sort.
        let summaries = [
            makeSummary(id: "old-a", at: anchor.adding(days: -4)),
            makeSummary(id: "t1",    at: anchor.adding(hours: -1)),
            makeSummary(id: "y1",    at: anchor.adding(days: -1)),
            makeSummary(id: "old-b", at: anchor.adding(days: -4).adding(hours: -3)),
            makeSummary(id: "t2",    at: anchor.adding(hours: -4)),
        ]
        let buckets = RunSummaryGrouping.group(summaries, now: anchor, calendar: gregorianUTC)
        #expect(buckets.count == 3)
        #expect(buckets[0].section == .today)
        #expect(buckets[0].summaries.map(\.runID) == ["t1", "t2"])
        #expect(buckets[1].section == .yesterday)
        #expect(buckets[1].summaries.map(\.runID) == ["y1"])
        #expect(buckets[2].summaries.map(\.runID) == ["old-a", "old-b"])
    }

    @Test("Distinct older days produce distinct .day buckets")
    func distinctOlderDays() {
        let summaries = [
            makeSummary(id: "may13",  at: anchor.adding(days: -4)),     // May 13
            makeSummary(id: "may10a", at: anchor.adding(days: -7)),     // May 10
            makeSummary(id: "may10b", at: anchor.adding(days: -7).adding(hours: -3)),
        ]
        let buckets = RunSummaryGrouping.group(summaries, now: anchor, calendar: gregorianUTC)
        #expect(buckets.count == 2)
        // Newer first.
        #expect(buckets[0].summaries.map(\.runID) == ["may13"])
        #expect(buckets[1].summaries.map(\.runID) == ["may10a", "may10b"])
    }

    // MARK: - Section header formatting

    @Test("Section header — Today / Yesterday")
    func headerSpecial() {
        #expect(RunSummaryGrouping.formatSectionHeader(for: .today, now: anchor) == "Today")
        #expect(RunSummaryGrouping.formatSectionHeader(for: .yesterday, now: anchor) == "Yesterday")
    }

    @Test("Section header — same-year older day omits year")
    func headerSameYear() {
        // Anchor year is 2026. A May 13 2026 section header reads "May 13"
        // (not "May 13 2026") — design doc §04 example "Today / Yesterday /
        // May 13".
        let mayThirteen = gregorianUTC.startOfDay(for: anchor.adding(days: -4))
        let header = RunSummaryGrouping.formatSectionHeader(
            for: .day(mayThirteen),
            now: anchor,
            calendar: gregorianUTC,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(header.contains("May"), Comment(rawValue: "expected month name in header; got '\(header)'"))
        #expect(header.contains("13"), Comment(rawValue: "expected day-of-month in header; got '\(header)'"))
        #expect(!header.contains("2026"),
                Comment(rawValue: "same-year header must NOT carry the year; got '\(header)'"))
    }

    @Test("Section header — different-year older day includes year")
    func headerDifferentYear() {
        // 2025-12-30 viewed from 2026-05-17.
        let lastYear = makeDate(year: 2025, month: 12, day: 30)
        let header = RunSummaryGrouping.formatSectionHeader(
            for: .day(lastYear),
            now: anchor,
            calendar: gregorianUTC,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(header.contains("2025"),
                Comment(rawValue: "cross-year header must carry the year; got '\(header)'"))
    }

    // MARK: - Cell formatting

    @Test("formatDuration — nil renders em-dash")
    func durationNil() {
        #expect(RunSummaryGrouping.formatDuration(nanos: nil) == "—")
    }

    @Test("formatDuration — sub-second renders to 2dp")
    func durationSubsecond() {
        #expect(RunSummaryGrouping.formatDuration(nanos: 340_000_000) == "0.34s")
    }

    @Test("formatDuration — seconds-only branch")
    func durationSeconds() {
        #expect(RunSummaryGrouping.formatDuration(nanos: 23_000_000_000) == "23s")
    }

    @Test("formatDuration — minutes + seconds")
    func durationMinutes() {
        // 5m 23s == 323s == 323_000_000_000 ns.
        #expect(RunSummaryGrouping.formatDuration(nanos: 323_000_000_000) == "5m 23s")
    }

    @Test("formatDuration — hours + minutes")
    func durationHours() {
        // 1h 12m == 72m == 4320s.
        #expect(RunSummaryGrouping.formatDuration(nanos: 4_320_000_000_000) == "1h 12m")
    }

    @Test("formatDuration — seconds boundary rounds up into minutes")
    func durationSecondsBoundary() {
        // 59.6 s rounds to 60 s. The pre-rounding branch decision used to
        // produce "60s" (inconsistent: branch said "seconds-only", number
        // said "1 minute"). The post-rounding decision puts it cleanly in
        // the minutes branch.
        let nanos = UInt64(59.6 * 1_000_000_000)
        #expect(RunSummaryGrouping.formatDuration(nanos: nanos) == "1m 0s")
    }

    @Test("formatDuration — hours boundary rounds up cleanly")
    func durationHoursBoundary() {
        // 3599.6 s == ~59m 59.6s. After rounding, that's 3600 s == 1h 0m.
        let nanos = UInt64(3599.6 * 1_000_000_000)
        #expect(RunSummaryGrouping.formatDuration(nanos: nanos) == "1h 0m")
    }

    @Test("formatTimeOfDay — pinned locale renders HH:MM")
    func timeOfDayPosix() {
        // 14:32 in UTC under en_US_POSIX. POSIX is 24-hour by convention,
        // so we can assert an exact string. Production callers use
        // Locale.current — verified visually via #Preview, not in tests.
        let date = makeDate(year: 2026, month: 5, day: 17, hour: 14, minute: 32)
        let rendered = RunSummaryGrouping.formatTimeOfDay(
            date,
            calendar: gregorianUTC,
            locale: Locale(identifier: "en_US_POSIX")
        )
        // POSIX time-style .short renders "14:32".
        #expect(rendered == "14:32",
                Comment(rawValue: "expected '14:32'; got '\(rendered)'"))
    }

    @Test("presetPillText — uppercases label, leaves non-letters alone")
    func presetText() {
        #expect(RunSummaryGrouping.presetPillText(for: "smoke") == "SMOKE")
        #expect(RunSummaryGrouping.presetPillText(for: "full") == "FULL")
        // Empty label stays empty — the sidebar's preset slot would render
        // an empty pill; that's a caller-side concern, not the formatter's.
        #expect(RunSummaryGrouping.presetPillText(for: "") == "")
    }

    @Test("formatCaseCount — complete vs truncated")
    func caseCount() {
        #expect(RunSummaryGrouping.formatCaseCount(completed: 342, total: 342) == "342 cases")
        #expect(RunSummaryGrouping.formatCaseCount(completed: 342, total: 600) == "342/600")
        #expect(RunSummaryGrouping.formatCaseCount(completed: 1, total: 1) == "1 case")
    }

    @Test("presetPillStyle — known and unknown labels")
    func presetStyle() {
        // `PillStyle` is declared in a file that imports SwiftUI under the
        // app target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting,
        // so its auto-synthesized `Equatable` conformance is MainActor-
        // isolated. Comparing via `==` from a nonisolated test produces
        // Swift 6 warnings. Pattern-match instead — same coverage, no
        // cross-isolation hop. (Fixing PillStyle to be nonisolated is a
        // Pill.swift edit; out of scope for Item 2.)
        assertStyle(RunSummaryGrouping.presetPillStyle(for: "smoke"),    is: .accent)
        assertStyle(RunSummaryGrouping.presetPillStyle(for: "standard"), is: .neutral)
        assertStyle(RunSummaryGrouping.presetPillStyle(for: "full"),     is: .info)
        assertStyle(RunSummaryGrouping.presetPillStyle(for: "custom"),   is: .warn)
        // Unknown label falls back to neutral so a future preset doesn't
        // crash the sidebar before its style mapping lands.
        assertStyle(RunSummaryGrouping.presetPillStyle(for: "marathon"), is: .neutral)
    }

    /// Pattern-match assertion for `PillStyle` without `==`. See callers.
    private func assertStyle(
        _ actual: PillStyle,
        is expected: PillStyle,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actualName = styleName(actual)
        let expectedName = styleName(expected)
        #expect(actualName == expectedName,
                Comment(rawValue: "expected style '\(expectedName)'; got '\(actualName)'"),
                sourceLocation: sourceLocation)
    }

    private func styleName(_ style: PillStyle) -> String {
        switch style {
        case .pass:    return "pass"
        case .fail:    return "fail"
        case .warn:    return "warn"
        case .info:    return "info"
        case .neutral: return "neutral"
        case .approx:  return "approx"
        case .accent:  return "accent"
        }
    }

    // MARK: - Fixtures

    /// Anchor "now" for all relative-date tests: 2026-05-17 14:00:00 UTC.
    /// Hand-picked far from a DST boundary so calendar arithmetic stays
    /// trivial; tests that need explicit dates use `makeDate(...)` below.
    private var anchor: Date {
        makeDate(year: 2026, month: 5, day: 17, hour: 14)
    }

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

    private func makeSummary(id: String, at timestamp: Date) -> RunSummary {
        RunSummary(
            runID: id,
            timestamp: timestamp,
            gitSha: "abc1234",
            branch: "main",
            preset: "smoke",
            caseCount: 1,
            completedCaseCount: 1,
            hardwareFingerprint: "test",
            thermalEscalations: 0,
            wallTimeNanos: 1_000_000_000
        )
    }
}

// MARK: - Date convenience for tests

private extension Date {
    func adding(days: Int = 0, hours: Int = 0, minutes: Int = 0) -> Date {
        let seconds = TimeInterval(days * 86_400 + hours * 3_600 + minutes * 60)
        return addingTimeInterval(seconds)
    }
}
