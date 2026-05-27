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
            footer
        }
        .frame(width: 980, height: 720)
        .background(VSB.Surface.bg)
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
                // Size pills use the smaller `Pill`-radius (3) — they
                // read as pills, not grid chips. Same selectable-chip
                // background/border treatment otherwise.
                .selectableChip(isSelected: isSelected, cornerRadius: 3)
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
                ForEach(Array(T.allCases), id: \.self) { value in
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

    /// Sticky bottom strip. Live-estimate trio on the left (em-dash
    /// placeholders in 4a; 4b makes them live), Cancel + Start on the
    /// right.
    private var footer: some View {
        HStack(spacing: 16) {
            estimateBlock
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

    /// Three accent-colored numerics matching the design doc §05 footer
    /// shape (`~342 cases · ~4m 50s · ~12 MB JSON`). In 4a all three
    /// cells render as `—` placeholders; 4b wires the live estimator.
    ///
    /// **Cell shape varies by metric.** The cases cell + bytes cell have
    /// a trailing unit label (`cases` / `MB JSON`); the wall-clock cell
    /// is a composite duration string (`4m 50s`) with no separate unit
    /// because the duration's `m`/`s` are baked into the value itself.
    /// Modeled here as `unit: String?` — nil = no trailing label.
    private var estimateBlock: some View {
        HStack(spacing: 8) {
            estimateCell(value: "—", unit: "cases")
            dot
            estimateCell(value: "—", unit: nil)
            dot
            estimateCell(value: "—", unit: "MB JSON")
        }
    }

    private func estimateCell(value: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).vsbMonoNumber(color: VSB.Impl.vectorCore.opacity(0.5))
            if let unit {
                Text(unit).vsbMonoSha()
            }
        }
    }

    private var dot: some View {
        Text("·").vsbMonoSha()
    }

    /// `Start ⌘↵` — emphasized primary per design doc, disabled in 4a
    /// since the action wires up in 4c. Native macOS prominent button
    /// style gives us the cyan glow effect automatically.
    private var startButton: some View {
        Button {
            // Wired in Item 4c — invokes RunController(...).run()
        } label: {
            HStack(spacing: 6) {
                Text("Start")
                Text("⌘↵").vsbMonoSha(color: VSB.Text.lo)
            }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(true)
        .help("Coming in Item 4c — invokes RunController in-process")
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

#Preview("RunConfigView — smoke default") {
    RunConfigView()
        .background(VSB.Surface.bg)
}
