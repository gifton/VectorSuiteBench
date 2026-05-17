import SwiftUI

/// Typography tokens for VectorSuiteBench.
///
/// Two families, three roles:
/// - **SF Pro Text** (system UI) carries labels, titles, and prose.
/// - **SF Mono with `monospacedDigit()`** is *strictly required* for every
///   number, every Git SHA, every axis label. A P99 number jittering by
///   half a character across rows is the kind of cognitive tax that erodes
///   trust in a benchmarking tool.
///
/// Apply via the `View` modifiers at the bottom of this file
/// (`.vsbBody()`, `.vsbMonoNumber()`, etc.) — they bundle font + tracking
/// + foreground so call sites stay one line. **Tracking values from the
/// design doc § 02 are applied inside the modifiers**, not on the `Font`
/// itself — SwiftUI's `Font` doesn't carry tracking.
extension VSB {
    enum Fonts {
        /// Canvas / artboard titles. Rare; used only for hero empty states.
        /// Design doc: 22/600/−0.4 (tracking applied by `.vsbDisplay()`).
        static let display     = Font.system(size: 22, weight: .semibold)

        /// Section headers, modal titles.
        /// Design doc: 15/600/−0.2 (tracking applied by `.vsbTitle()`).
        static let title       = Font.system(size: 15, weight: .semibold)

        /// App default — paragraph copy, default UI text.
        /// Design doc: 12.5/400/0.
        static let body        = Font.system(size: 12.5, weight: .regular)

        /// Column heads, eyebrow labels. Used with `.textCase(.uppercase)` +
        /// extra tracking; see `.vsbCaption()` modifier below.
        /// Design doc: 10/600/0.6.
        static let caption     = Font.system(size: 10, weight: .semibold)

        /// **Every number cell in the app uses this font.** SF Mono with
        /// `monospacedDigit()` so digits sit on a tabular grid — a P99 cell
        /// at 1234 ns and one at 142 ns align vertically without flicker
        /// when sorting.
        /// Design doc: 13/500/0 · tabular.
        static let monoNumber  = Font.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit()

        /// Smaller mono variant — git SHAs, chart axis labels, footer status,
        /// in-cell unit suffixes (`ns`, `GB/s`).
        /// Design doc: 10–11/500/0.2 (tracking applied by `.vsbMonoSha()`).
        static let monoShaAxis = Font.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit()

        /// Smallest mono — pill / badge text. Always paired with `.tracking(0.4)`
        /// at minimum so the all-caps reads cleanly at 10pt; see `.vsbMonoBadge()`.
        /// Design doc: 10/700/0.4–0.6.
        static let monoBadge   = Font.system(size: 10, weight: .heavy, design: .monospaced).monospacedDigit()
    }
}

// MARK: - View modifiers

extension View {
    /// Display headline. SF Pro 22 semibold at `text.hi`, tracking −0.4.
    func vsbDisplay(color: Color = VSB.Text.hi) -> some View {
        self.font(VSB.Fonts.display)
            .tracking(-0.4)
            .foregroundStyle(color)
    }

    /// Section / modal titles. SF Pro 15 semibold at `text.hi`, tracking −0.2.
    func vsbTitle(color: Color = VSB.Text.hi) -> some View {
        self.font(VSB.Fonts.title)
            .tracking(-0.2)
            .foregroundStyle(color)
    }

    /// Default app body text. SF Pro 12.5 regular at `text.hi`.
    func vsbBody(color: Color = VSB.Text.hi) -> some View {
        self.font(VSB.Fonts.body)
            .foregroundStyle(color)
    }

    /// Eyebrow / column-head labels. Uppercase, tracked 0.6, demoted color —
    /// supports the data, never competes with it.
    func vsbCaption(color: Color = VSB.Text.lo) -> some View {
        self.font(VSB.Fonts.caption)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(color)
    }

    /// Number cell. SF Mono 13 medium with tabular digits at `text.hi`.
    /// Pass `color: VSB.Impl.vectorCore` to render VectorCore numbers in the
    /// accent hue (design principle P-02: VectorCore owns the saturated color).
    func vsbMonoNumber(color: Color = VSB.Text.hi) -> some View {
        self.font(VSB.Fonts.monoNumber)
            .foregroundStyle(color)
    }

    /// Git SHA + chart axis label + unit suffix. SF Mono 11 at `text.lo`,
    /// tracking 0.2.
    func vsbMonoSha(color: Color = VSB.Text.lo) -> some View {
        self.font(VSB.Fonts.monoShaAxis)
            .tracking(0.2)
            .foregroundStyle(color)
    }

    /// Pill / badge text. SF Mono 10 heavy, tracking 0.4. Pass `color:` to
    /// match the surrounding pill semantic (e.g. `.vsbMonoBadge(color: VSB.Status.fail)`
    /// for the redacted `ERR` cell of a failed row).
    func vsbMonoBadge(color: Color = VSB.Text.md) -> some View {
        self.font(VSB.Fonts.monoBadge)
            .tracking(0.4)
            .foregroundStyle(color)
    }
}

// MARK: - Preview

#Preview("Typography specimen") {
    VStack(alignment: .leading, spacing: 14) {
        Text("Display 22/600/−0.4").vsbDisplay()
        Text("Title 15/600/−0.2").vsbTitle()
        Text("Body 12.5/400/0 — most of the app text reads at this size and weight.").vsbBody()
        Text("eyebrow / column head").vsbCaption()
        Text("142 ns").vsbMonoNumber()
        Text("142 ns").vsbMonoNumber(color: VSB.Impl.vectorCore)
        Text("abc1234 · main").vsbMonoSha()
        Text("VERIFIED").vsbMonoBadge(color: VSB.Status.pass)
    }
    .padding(24)
    .frame(width: 480, alignment: .leading)
    .background(VSB.Surface.bg)
}
