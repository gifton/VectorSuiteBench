import Foundation
import BenchKit

/// Pure functions that bucket `[RunSummary]` into section-grouped, date-ordered
/// rows for `RunListSidebar`. Lives next to the view but is intentionally
/// SwiftUI-free so the bucketing logic is unit-testable without view inspection.
///
/// **Section taxonomy** (per design doc §04: "Today / Yesterday / May 13"):
/// - `.today`     — calendar-day match against `now`.
/// - `.yesterday` — one calendar day before `now`.
/// - `.day(Date)` — any other calendar day; section header is formatted
///   inside `formatSectionHeader(for:now:calendar:)` so the view never has
///   to introspect the section.
///
/// **Ordering invariants** the view relies on:
/// 1. Sections appear newest-first (Today first, then Yesterday, then older).
/// 2. Within a section, summaries are newest-first by `timestamp`.
/// 3. Sections never overlap by date — a summary lands in exactly one bucket.
///
/// `now` and `calendar` are explicit parameters so tests can pin the clock
/// and the locale without monkeying with `Calendar.current` or `Date()`.
enum RunSummaryGrouping {

    /// Section bucket identifier. The header label is computed via
    /// `formatSectionHeader(for:now:calendar:)`, not stored here — keeps the
    /// enum cheap to compare and Hashable for SwiftUI's `Section(id:)` keying.
    ///
    /// **`nonisolated`** — the app target sets
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise
    /// make this enum's auto-synthesized `Equatable` conformance
    /// MainActor-isolated. Tests run on a nonisolated context and would
    /// emit Swift 6 errors. Pure value types like this one should opt out.
    nonisolated enum Section: Hashable, Sendable {
        case today
        case yesterday
        /// Calendar day at midnight (start-of-day in the supplied calendar)
        /// for any run older than yesterday. Using start-of-day as the key
        /// guarantees same-day runs cluster regardless of HH:MM:SS drift.
        case day(Date)
    }

    /// One section in the sidebar: the bucket identifier + the summaries
    /// in it, newest-first.
    struct Bucket: Identifiable, Sendable {
        let section: Section
        let summaries: [RunSummary]

        /// Hashable identity for SwiftUI. `.day(Date)` cases hash distinctly
        /// per calendar day; `.today`/`.yesterday` are stable singletons.
        var id: Section { section }
    }

    // MARK: - Public API

    /// Bucket and order `summaries` by relative date.
    ///
    /// Single linear pass over the (already-newest-first by `RunStore.updateIndex`)
    /// input. Calendar lookups are cached implicitly by Foundation's calendar
    /// implementation, so the cost stays O(n) for the input size you'd
    /// realistically see (≤ a few hundred runs).
    static func group(
        _ summaries: [RunSummary],
        now: Date,
        calendar: Calendar = .current
    ) -> [Bucket] {
        guard !summaries.isEmpty else { return [] }

        // Sort newest-first defensively — RunStore already does this on
        // index write, but we'd rather not depend on a caller-side invariant
        // for ordering correctness.
        let sorted = summaries.sorted { $0.timestamp > $1.timestamp }
        let todayStart = calendar.startOfDay(for: now)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else {
            // `Calendar.date(byAdding:)` returning nil here would mean the
            // supplied calendar is pathological (no day component). Fall
            // back to a single "older" bucket per day so we don't lose data.
            return [Bucket(section: .day(todayStart), summaries: sorted)]
        }

        var buckets: [(Section, [RunSummary])] = []
        var current: (section: Section, items: [RunSummary])? = nil

        func flush() {
            if let c = current { buckets.append((c.section, c.items)) }
            current = nil
        }

        for summary in sorted {
            let dayStart = calendar.startOfDay(for: summary.timestamp)
            let section: Section
            if dayStart == todayStart {
                section = .today
            } else if dayStart == yesterdayStart {
                section = .yesterday
            } else {
                section = .day(dayStart)
            }
            if current?.section == section {
                current?.items.append(summary)
            } else {
                flush()
                current = (section, [summary])
            }
        }
        flush()

        return buckets.map { Bucket(section: $0.0, summaries: $0.1) }
    }

    /// Display label for a section header. "Today" / "Yesterday" / "May 13"
    /// (or "May 13 2025" when the section's year differs from `now`'s year —
    /// avoids ambiguity at year boundaries without burning a year on every
    /// row).
    static func formatSectionHeader(
        for section: Section,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        switch section {
        case .today:     return "Today"
        case .yesterday: return "Yesterday"
        case .day(let date):
            let nowYear = calendar.component(.year, from: now)
            let dayYear = calendar.component(.year, from: date)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(
                dayYear == nowYear ? "MMMd" : "MMMdyyyy"
            )
            return formatter.string(from: date)
        }
    }

    // MARK: - Row-cell formatting (pure)

    /// `HH:MM` rendering of a run's start time within its day. Locale-aware
    /// (24-hour locales get 24-hour formatting; 12-hour locales get "2:32 PM").
    /// Used on line 1 of every sidebar row.
    static func formatTimeOfDay(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Compact wall-clock duration: "0.34s" / "23s" / "5m 23s" / "1h 12m".
    /// `nil` (pre-1.2 runs or finalize-without-stamp) renders as an em-dash
    /// so the column doesn't collapse silently.
    ///
    /// **Boundary handling.** The seconds-vs-minutes branch decides on the
    /// rounded value, not the raw — so 59.6s renders as "1m 0s" (the same
    /// number a user would write down), not "60s". Same logic at the
    /// hour boundary.
    static func formatDuration(nanos: UInt64?) -> String {
        guard let nanos else { return "—" }
        let totalSeconds = Double(nanos) / 1_000_000_000
        if totalSeconds < 1 {
            return String(format: "%.2fs", totalSeconds)
        }
        // Round first so the branch decision matches the displayed number.
        // Without this, 59.6 s falls into the seconds branch but
        // `Int(59.6.rounded()) == 60` renders "60s" — an internally
        // inconsistent reading.
        let roundedSeconds = Int(totalSeconds.rounded())
        if roundedSeconds < 60 {
            return "\(roundedSeconds)s"
        }
        let totalMinutes = roundedSeconds / 60
        if totalMinutes < 60 {
            let secs = roundedSeconds - totalMinutes * 60
            return "\(totalMinutes)m \(secs)s"
        }
        let hours = totalMinutes / 60
        let mins = totalMinutes - hours * 60
        return "\(hours)h \(mins)m"
    }

    /// "342 cases" when complete; "342/600" when truncated. Tail-end of
    /// line 3. Singular "1 case" is honored — small things matter when an
    /// engineer is scanning 80 rows.
    static func formatCaseCount(completed: Int, total: Int) -> String {
        if completed == total {
            return total == 1 ? "1 case" : "\(total) cases"
        }
        return "\(completed)/\(total)"
    }

    /// Map `RunSummary.preset` (free-form string from `RunPreset.label`) to
    /// the design-doc pill style. Unknown labels fall back to `.neutral` so
    /// a future preset doesn't crash the sidebar before its style lands.
    ///
    /// **Provisional mapping.** The design doc says preset is "a colored
    /// chip" but is silent on which color per preset. The mapping below is
    /// the implementer's pick — accent for the dev-loop preset (smoke),
    /// neutral for the default (standard), info for the long-form preset
    /// (full), and warn for off-the-rails configurations (custom). Worth
    /// raising in the next design review; this is the only call site so
    /// a future restyling is a single-function change.
    ///
    /// Locked decision §1.5/2: pills are always present.
    static func presetPillStyle(for label: String) -> PillStyle {
        switch label {
        case "smoke":    return .accent     // fast / dev-loop runs read accent-tinted
        case "standard": return .neutral
        case "full":     return .info       // long runs get a quiet hue so they stand out
        case "custom":   return .warn       // off-the-rails configurations should be visually flagged
        default:         return .neutral
        }
    }

    /// Uppercased preset label for the pill text. Stable across locale; the
    /// design doc renders these as ALL-CAPS chips.
    static func presetPillText(for label: String) -> String {
        label.uppercased()
    }
}
