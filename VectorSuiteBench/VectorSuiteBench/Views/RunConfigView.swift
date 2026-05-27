import SwiftUI
import BenchKit

/// New Run modal — design doc §05. A 980 × 720 sheet dropped from the
/// window's titlebar with five sections + a sticky live-estimate footer.
///
/// **Scope in 4a.** Layout-only: the view renders, the model
/// (`RunConfig`) drives every section's selected/unselected state, and
/// the preset-flips-to-custom logic is wired. The estimator footer
/// renders placeholder em-dashes (4b makes the numbers live). The Start
/// button is visible + disabled (4c flips it on and wires the
/// `RunController` invocation).
///
/// **Layout structure.** A single ScrollView holds five sections in a
/// VStack. Each section uses a 180 px label gutter on the left (title +
/// hint in caption-style) and form controls on the right per the design
/// doc. Hair-line dividers between sections so the grid reads as one
/// surface.
///
/// **Sheet sizing.** Fixed at 980 × 720 via `.frame(width:height:)` on
/// the body root. macOS allows the user to grow the window the sheet
/// belongs to, but the sheet itself stays at the spec'd size — matches
/// the design doc's pixel-pinned mockup and prevents the layout from
/// silently rearranging at unusual window sizes.
struct RunConfigView: View {

    @State private var config = RunConfig()

    /// Orchestrator for the run itself. Provided by `AppRoot` so the
    /// sheet's lifetime doesn't interfere with the run's lifetime —
    /// dismissing the sheet on Start (the standard pattern) doesn't
    /// stop the benchmark.
    let invocation: RunInvocation

    /// `true` after the user has clicked Start at least once in this
    /// sheet session. Gates the inline error banner: when the user
    /// hasn't tried to start yet, the LiveStateChip's red state from
    /// a *prior* run shouldn't pollute the sheet UI. Once the user
    /// clicks Start, any sync failure becomes "their failure" and
    /// gets surfaced inline.
    @State private var didAttemptStart = false

    /// Native SwiftUI dismissal. Replaces an earlier `onDismiss` closure
    /// parameter — `.dismiss` is the macOS-idiomatic path and it covers
    /// the three dismissal triggers (Cancel button, Escape key,
    /// click-outside) through one mechanism. The parent's
    /// `.sheet(isPresented:)` binding flips to false automatically when
    /// `dismiss()` fires.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().background(VSB.Surface.divider)
            ScrollView {
                VStack(spacing: 0) {
                    section(label: "Preset", hint: "Run shape") {
                        presetSection
                    }
                    sectionDivider
                    section(label: "Operations", hint: "Kernels to measure") {
                        opsSection
                    }
                    sectionDivider
                    section(label: "Implementations", hint: "Candidates to compare") {
                        implsSection
                    }
                    sectionDivider
                    section(label: "Vector sizes", hint: "Inner dimension n") {
                        sizesSection
                    }
                    sectionDivider
                    section(label: "Budgets", hint: "Sampling and limits") {
                        budgetsSection
                    }
                }
            }
            Divider().background(VSB.Surface.divider)
            if didAttemptStart, let reason = invocation.failureReason {
                errorBanner(reason)
            }
            footer
        }
        .frame(width: 980, height: 720)
        .background(VSB.Surface.bg)
    }

    // MARK: - Error banner (synchronous-failure surface)

    /// Inline warn-tinted banner that surfaces an `invocation.failed`
    /// reason when the user has clicked Start in this sheet session
    /// and the start failed synchronously (e.g. empty registry). The
    /// banner stays scoped to this sheet — opening a fresh sheet
    /// resets `didAttemptStart`, so stale failures from prior async
    /// runs don't bleed into a new configure session. Visual treatment
    /// mirrors the `ThermalBanner` in `RunSummaryHeader`.
    private func errorBanner(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(VSB.Status.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Start failed").vsbBody(color: VSB.Status.warn)
                Text(reason).vsbMonoSha(color: VSB.Text.md)
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
        .accessibilityLabel(Text("Start failed. \(reason)"))
    }

    // MARK: - Title bar

    /// Compact header strip. macOS sheets don't render a native title
    /// bar, so we paint our own at `VSB.Surface.s0` to anchor the visual
    /// hierarchy. The eyebrow (caption) + title (semibold) pattern
    /// matches the design-doc artboard.
    private var titleBar: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Run").vsbCaption()
                Text("Configure benchmark").vsbTitle()
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(VSB.Surface.s0)
    }

    // MARK: - Section shell

    /// One section row: 180 px label gutter on the left, content on the
    /// right. Per design doc §05.
    private func section<Content: View>(
        label: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).vsbTitle()
                Text(hint).vsbMonoSha()
            }
            .frame(width: 180, alignment: .leading)
            .padding(.trailing, 16)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var sectionDivider: some View {
        Divider().background(VSB.Surface.hair)
    }

    // MARK: - Section 1: Preset

    /// Segmented control over `PresetSelection.allCases`. Selecting one
    /// of `smoke / standard / full` pre-fills every section below;
    /// `.custom` is the "you took the controls" state that any other
    /// section mutation flips to.
    private var presetSection: some View {
        HStack(spacing: 6) {
            ForEach(PresetSelection.allCases) { p in
                presetChip(p)
            }
            Spacer()
        }
    }

    private func presetChip(_ p: PresetSelection) -> some View {
        let isSelected = config.preset == p
        return Button {
            config.selectPreset(p)
        } label: {
            Text(p.label)
                .vsbMonoBadge(color: isSelected ? VSB.Impl.vectorCore : VSB.Text.md)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .selectableChip(isSelected: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Section 2: Operations

    /// 4-column grid of `CheckboxChip`s — one per `OpKind` (excluding
    /// the `.null` sentinel which is the harness self-bench, not a
    /// user-facing op).
    private var opsSection: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
            spacing: 8
        ) {
            ForEach(opsCatalog, id: \.self) { op in
                CheckboxChip(
                    title: op.rawValue,
                    subtitle: op.mathShorthand,
                    isSelected: config.ops.contains(op),
                    action: { config.toggleOp(op) }
                )
            }
        }
    }

    /// All user-facing ops in display order. `.null` filtered because
    /// it's the harness self-bench, not a kernel anyone configures.
    private var opsCatalog: [OpKind] {
        OpKind.allCases.filter { $0 != .null }
    }

    // MARK: - Section 3: Implementations

    /// 2-column grid of `ImplChip`s. Wider cells than the ops grid
    /// because impls carry richer metadata (color swatch + label +
    /// optional APPROX pill).
    private var implsSection: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
            spacing: 8
        ) {
            ForEach(ImplKind.allCases, id: \.self) { impl in
                ImplChip(
                    implDisplay: impl.display,
                    // The current `ImplKind` enum has no
                    // approximate-by-default cases — approximate is an
                    // `ImplClass` property selected per workload, not
                    // per impl-kind. The chip param is present for
                    // future use (e.g. a `metal-approx` flavor).
                    isApproximate: false,
                    isSelected: config.impls.contains(impl),
                    action: { config.toggleImpl(impl) }
                )
            }
        }
    }

    // MARK: - Section 4: Vector sizes

    /// Wrapping pill grid over the 21 powers of 2 from 16 to 16M.
    /// `FlowLayout` lays out left-to-right with size-appropriate cell
    /// widths — a `[16]` next to a `[16M]` would look uneven in a
    /// fixed-column grid.
    private var sizesSection: some View {
        FlowLayout(hSpacing: 6, vSpacing: 6) {
            ForEach(VectorSizeCatalog.all, id: \.self) { n in
                sizePill(n)
            }
        }
    }

    private func sizePill(_ n: Int) -> some View {
        let isSelected = config.sizes.contains(n)
        return Button {
            config.toggleSize(n)
        } label: {
            Text(VectorSizeCatalog.label(for: n))
                .vsbMonoBadge(color: isSelected ? VSB.Impl.vectorCore : VSB.Text.md)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                // Size pills use `VSB.Radius.pill` (3) instead of the
                // chip default — they read as pills, not grid chips.
                // Same selectable-chip background/border treatment.
                .selectableChip(isSelected: isSelected, cornerRadius: VSB.Radius.pill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Size \(n)"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Section 5: Budgets

    /// 3 × 2 grid of native `Picker`s. Each cell: label (caption) +
    /// menu picker + (optional) mono caption explaining implications.
    private var budgetsSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
                budgetField(
                    label: "Total budget",
                    caption: "Aborts the run when exceeded",
                    selection: Binding(
                        get: { config.totalBudget },
                        set: { config.setTotalBudget($0) }
                    )
                )
                budgetField(
                    label: "Per-case",
                    caption: "Aborts the current case",
                    selection: Binding(
                        get: { config.perCaseBudget },
                        set: { config.setPerCaseBudget($0) }
                    )
                )
                budgetField(
                    label: "Samples",
                    caption: "Single-shot samples per case",
                    selection: Binding(
                        get: { config.sampleCount },
                        set: { config.setSampleCount($0) }
                    )
                )
            }
            GridRow {
                budgetField(
                    label: "Modes",
                    caption: "Throughput needs LOOP",
                    selection: Binding(
                        get: { config.modes },
                        set: { config.setModes($0) }
                    )
                )
                budgetField(
                    label: "Verify",
                    caption: "Spec §5 requires for FP",
                    selection: Binding(
                        get: { config.verify },
                        set: { config.setVerify($0) }
                    )
                )
                budgetField(
                    label: "Abort policy",
                    caption: "On per-case timeout",
                    selection: Binding(
                        get: { config.abortPolicy },
                        set: { config.setAbortPolicy($0) }
                    )
                )
            }
        }
    }

    /// One budget-grid cell: label + menu Picker + caption. Generic over
    /// `T: CaseIterable & Hashable & Identifiable` so all six budget
    /// enums use the same widget.
    private func budgetField<T: CaseIterable & Hashable & Identifiable>(
        label: String,
        caption: String,
        selection: Binding<T>
    ) -> some View where T.AllCases: RandomAccessCollection, T: BudgetLabelable {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).vsbCaption()
            Picker("", selection: selection) {
                // `T.AllCases` is already RandomAccessCollection per
                // the where-clause; ForEach takes it directly. Earlier
                // `Array(T.allCases)` was an eager allocation per render.
                ForEach(T.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 120)
            Text(caption).vsbMonoSha()
        }
    }

    // MARK: - Footer

    /// Sticky bottom strip. Live-estimate trio on the left + breakdown
    /// caption, Cancel + Start on the right.
    ///
    /// **Accessibility.** The estimate cells + breakdown are grouped
    /// under one `.accessibilityElement(children: .combine)` so
    /// VoiceOver reads them as a single coherent sentence — engineers
    /// hear "Estimated 342 cases, 4m 50s, 12 MB JSON. 5 ops · 5 impls
    /// · 7 sizes · shot + loop." instead of five fragmented chunks.
    /// Cancel + Start stay as native buttons with their own a11y.
    private var footer: some View {
        let estimate = RunConfigEstimator.estimate(config)
        return HStack(spacing: 16) {
            HStack(spacing: 16) {
                estimateBlock(estimate)
                breakdownCaption(estimate.breakdown)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(footerAccessibilityLabel(estimate)))
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(".", modifiers: .command)
                .buttonStyle(.bordered)
            startButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(VSB.Surface.s0)
    }

    /// VoiceOver label for the footer estimate block. Composes the
    /// already-formatted cells into one phrase plus the breakdown.
    private func footerAccessibilityLabel(_ estimate: RunConfigEstimator.Estimate) -> String {
        let cases = estimate.cases == 1 ? "1 case" : "\(estimate.cases) cases"
        let wall = RunConfigEstimator.formatWall(estimate.wallSeconds)
        let bytes = "\(RunConfigEstimator.formatBytes(estimate.bytes)) \(RunConfigEstimator.formatBytesUnit(estimate.bytes))"
        return "Estimated \(cases), \(wall), \(bytes). \(estimate.breakdown)."
    }

    /// Three accent-colored numerics matching the design doc §05 footer
    /// shape (`~342 cases · ~4m 50s · ~12 MB JSON`). When the
    /// configuration produces zero cases, every cell renders `0` /
    /// `0s` / `0 KB JSON` honestly — surfacing that the user has
    /// configured an empty run rather than hiding the value.
    ///
    /// **Cell shape varies by metric.** The cases cell + bytes cell have
    /// a trailing unit label (`cases` / `MB JSON`); the wall-clock cell
    /// is a composite duration string (`4m 50s`) with no separate unit
    /// because the duration's `m`/`s` are baked into the value itself.
    /// Modeled here as `unit: String?` — nil = no trailing label.
    private func estimateBlock(_ estimate: RunConfigEstimator.Estimate) -> some View {
        HStack(spacing: 8) {
            // No `~` prefix on cases — the case count is the exact
            // Cartesian product of the user's selections, not an
            // estimate. Only `wall` and `bytes` carry the tilde because
            // those are roughed via the uniform-per-mode model.
            estimateCell(
                value: RunConfigEstimator.formatCases(estimate.cases),
                unit: estimate.cases == 1 ? "case" : "cases"
            )
            dot
            estimateCell(
                value: "~\(RunConfigEstimator.formatWall(estimate.wallSeconds))",
                unit: nil
            )
            dot
            estimateCell(
                value: "~\(RunConfigEstimator.formatBytes(estimate.bytes))",
                unit: RunConfigEstimator.formatBytesUnit(estimate.bytes)
            )
        }
    }

    private func estimateCell(value: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).vsbMonoNumber(color: VSB.Impl.vectorCore)
            if let unit {
                Text(unit).vsbMonoSha()
            }
        }
    }

    /// `"5 ops · 5 impls · 7 sizes · shot + loop"` — explains the
    /// arithmetic behind the case count. Sits right of the main
    /// estimate trio; same line, smaller font, demoted color.
    private func breakdownCaption(_ text: String) -> some View {
        Text(text).vsbMonoSha()
    }

    private var dot: some View {
        Text("·").vsbMonoSha()
    }

    /// `Start ⌘↵` — emphasized primary per design doc. Tap →
    /// `invocation.start(config:)` → **if the run started**, dismiss
    /// the sheet (background execution; toolbar's `LiveStateChip`
    /// reflects state, `+ New Run` swaps to `◼ Cancel`). **If the
    /// start failed synchronously** (e.g. empty registry filter), the
    /// sheet stays open and the inline `errorBanner` surfaces the
    /// reason so the user can fix the config without hunting for the
    /// toolbar chip's tooltip. Disabled while a run is already in
    /// flight (no concurrent runs).
    private var startButton: some View {
        Button {
            didAttemptStart = true
            invocation.start(config: config)
            if invocation.isRunning {
                dismiss()
            }
            // Else: start() set state to .failed synchronously
            // (or the run was already in flight, but the .disabled
            // guard below prevents the button from firing in that
            // case). Keep the sheet open so `errorBanner` can render.
        } label: {
            HStack(spacing: 6) {
                Text("Start")
                Text("⌘↵").vsbMonoSha(color: VSB.Text.lo)
            }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(invocation.isRunning)
        .help(invocation.isRunning
              ? "A run is already in flight — cancel it before starting another"
              : "Start the benchmark run (the sheet dismisses; progress shows in the toolbar)")
    }
}

// MARK: - BudgetLabelable

/// Trait conformance for the budget enums that the budget-field
/// generic picker consumes. Every budget enum carries a `.label`
/// already; this protocol exposes it generically so the picker can
/// render any of the six without per-enum code paths.
protocol BudgetLabelable {
    var label: String { get }
}

extension TotalBudget:     BudgetLabelable {}
extension PerCaseBudget:   BudgetLabelable {}
extension SampleCount:     BudgetLabelable {}
extension ModesSelection:  BudgetLabelable {}
extension VerifyPolicy:    BudgetLabelable {}
extension AbortPolicy:     BudgetLabelable {}

// MARK: - Preview

