import Foundation
import BenchKit

/// State for the New Run modal (design doc §05). Drives every section of
/// `RunConfigView` and is consumed by Item 4b's live estimator + Item
/// 4c's `RunController` invocation.
///
/// **`@MainActor @Observable`** — view-state container. Same pattern as
/// `CaseTableFilter` and `CalibrationStatus`.
///
/// **Preset model.** `selectPreset(_:)` applies the preset's defaults to
/// every section. After that, any user-driven mutation goes through one
/// of the `toggle*` / setter methods, which flip `preset` back to
/// `.custom` (locked behavior per plan §4: "Touching any control after
/// that quietly flips the chip to CUSTOM — no modal alert; visual cue
/// only"). This means the `preset` chip is **always honest**: it shows
/// what the configuration actually represents, not what the user
/// originally clicked.
@MainActor
@Observable
final class RunConfig {

    // MARK: - Sections

    /// Section 1 — preset chip. Always reflects current configuration:
    /// switches to `.custom` the moment any other section diverges from
    /// a preset's defaults.
    private(set) var preset: PresetSelection

    /// Section 2 — operations to run. Empty = no cases enabled.
    private(set) var ops: Set<OpKind>

    /// Section 3 — implementations to compare. Empty = no cases enabled.
    private(set) var impls: Set<ImplKind>

    /// Section 4 — vector sizes (inner dim `n`). Empty = no cases enabled.
    private(set) var sizes: Set<Int>

    // MARK: - Budgets (section 5)

    private(set) var totalBudget: TotalBudget
    private(set) var perCaseBudget: PerCaseBudget
    private(set) var sampleCount: SampleCount
    private(set) var modes: ModesSelection
    private(set) var verify: VerifyPolicy
    private(set) var abortPolicy: AbortPolicy

    // MARK: - Init

    /// Default: smoke preset preselected. Matches plan §5 first-launch
    /// flow (the empty store CTA opens the modal with `.smoke` set).
    init() {
        self.preset = .smoke
        // Pre-fill with smoke defaults; no `applyPresetDefaults` call so
        // `preset` doesn't bounce off the `.custom` flip during init.
        self.ops = PresetSelection.smoke.defaultOps
        self.impls = PresetSelection.smoke.defaultImpls
        self.sizes = PresetSelection.smoke.defaultSizes
        self.totalBudget = PresetSelection.smoke.defaultTotalBudget
        self.perCaseBudget = PresetSelection.smoke.defaultPerCaseBudget
        self.sampleCount = PresetSelection.smoke.defaultSampleCount
        self.modes = PresetSelection.smoke.defaultModes
        self.verify = PresetSelection.smoke.defaultVerify
        self.abortPolicy = PresetSelection.smoke.defaultAbortPolicy
    }

    // MARK: - Preset

    /// Apply a preset. `.custom` is special — it doesn't override the
    /// user's current selections (custom IS "whatever you have now"), it
    /// just flips the chip label.
    func selectPreset(_ p: PresetSelection) {
        preset = p
        guard p != .custom else { return }
        ops = p.defaultOps
        impls = p.defaultImpls
        sizes = p.defaultSizes
        totalBudget = p.defaultTotalBudget
        perCaseBudget = p.defaultPerCaseBudget
        sampleCount = p.defaultSampleCount
        modes = p.defaultModes
        verify = p.defaultVerify
        abortPolicy = p.defaultAbortPolicy
    }

    // MARK: - Section mutations (each flips preset → custom)

    /// Toggle an op in/out of the selection set. Sections 2/3/4 share
    /// this toggle pattern: tap to flip. Re-renders the chip's
    /// selected-state visual and (in 4b) recomputes the footer estimate.
    func toggleOp(_ op: OpKind) {
        if ops.contains(op) { ops.remove(op) } else { ops.insert(op) }
        markCustom()
    }

    func toggleImpl(_ impl: ImplKind) {
        if impls.contains(impl) { impls.remove(impl) } else { impls.insert(impl) }
        markCustom()
    }

    func toggleSize(_ n: Int) {
        if sizes.contains(n) { sizes.remove(n) } else { sizes.insert(n) }
        markCustom()
    }

    func setTotalBudget(_ b: TotalBudget) {
        totalBudget = b
        markCustom()
    }

    func setPerCaseBudget(_ b: PerCaseBudget) {
        perCaseBudget = b
        markCustom()
    }

    func setSampleCount(_ s: SampleCount) {
        sampleCount = s
        markCustom()
    }

    func setModes(_ m: ModesSelection) {
        modes = m
        markCustom()
    }

    func setVerify(_ v: VerifyPolicy) {
        verify = v
        markCustom()
    }

    func setAbortPolicy(_ a: AbortPolicy) {
        abortPolicy = a
        markCustom()
    }

    /// Mark the configuration as `.custom`. No-op when already custom so
    /// the Observation framework doesn't fire spurious change events.
    private func markCustom() {
        if preset != .custom {
            preset = .custom
        }
    }
}

// MARK: - PresetSelection

/// UI-layer preset choices. Maps to `BenchKit.RunPreset` when Item 4c
/// invokes `RunController` — kept separate from BenchKit's enum because
/// the BenchKit case carries associated `WallClockBudget` / `SampleCount`
/// / `[WorkloadID]` payloads that the modal builds at submission time.
nonisolated enum PresetSelection: String, Identifiable, CaseIterable, Hashable, Sendable {
    case smoke
    case standard
    case full
    case custom

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// Whether the preset is one of the three canned configurations
    /// (smoke/standard/full) or the open-ended `.custom`. Used by the
    /// preset segmented control to know which option "owns" defaults.
    var hasDefaults: Bool { self != .custom }

    // MARK: Preset defaults

    /// Default ops per preset. Sourced from plan §3 preset filter table.
    var defaultOps: Set<OpKind> {
        switch self {
        case .smoke:
            return [.dot, .l2dist, .cosine]
        case .standard, .full:
            return Set(OpKind.allCases).subtracting([.null])
        case .custom:
            return [.dot]
        }
    }

    /// Default impls per preset. Smoke restricts to one VectorCore
    /// flavor + Accelerate + naïve for fast turnaround; standard/full
    /// open the whole set.
    var defaultImpls: Set<ImplKind> {
        switch self {
        case .smoke:
            return [.vectorCore, .accelerate, .naive]
        case .standard, .full:
            return Set(ImplKind.allCases)
        case .custom:
            return [.vectorCore]
        }
    }

    /// Default vector sizes per preset (inner dim `n`). Plan §3 pins
    /// smoke at 512, standard at 256 + 1536, full sweeps wider.
    var defaultSizes: Set<Int> {
        switch self {
        case .smoke:
            return [512]
        case .standard:
            return [256, 1536]
        case .full:
            // The "real" workhorse sizes plus the long tail. Sizes
            // outside the registry's known set will produce 0 cases —
            // that's caught by 4b's estimator + the empty-state copy.
            return [64, 256, 512, 1024, 1536, 4096]
        case .custom:
            return [512]
        }
    }

    var defaultTotalBudget: TotalBudget {
        switch self {
        case .smoke:    return .thirtySeconds
        case .standard: return .fiveMinutes
        case .full:     return .fortyFiveMinutes
        case .custom:   return .fiveMinutes
        }
    }

    var defaultPerCaseBudget: PerCaseBudget {
        switch self {
        case .smoke:    return .hundredMs
        case .standard: return .oneSecond
        case .full:     return .fiveSeconds
        case .custom:   return .oneSecond
        }
    }

    var defaultSampleCount: SampleCount {
        switch self {
        case .smoke:    return .oneHundred
        case .standard: return .fiveHundred
        case .full:     return .oneThousand
        case .custom:   return .fiveHundred
        }
    }

    var defaultModes: ModesSelection {
        switch self {
        case .smoke:    return .shotOnly       // plan §3: "single-shot only"
        case .standard: return .both
        case .full:     return .both
        case .custom:   return .both
        }
    }

    var defaultVerify: VerifyPolicy {
        // Spec §5 mandates verification for every dense FP workload;
        // all presets default to Require. `Skip` is the explicit
        // engineer-opt-out for impls without an oracle.
        .require
    }

    var defaultAbortPolicy: AbortPolicy {
        // Skip remaining is the safer default: a runaway case shouldn't
        // poison samples of cases it didn't reach.
        .skipRemaining
    }
}

// MARK: - Budget enums

/// Total wall-clock budget for the entire run. Three fixed choices in
/// 4a; custom-duration entry is deferred to a later phase if engineers
/// ask for it (most won't — these three cover the three preset shapes).
nonisolated enum TotalBudget: String, Identifiable, CaseIterable, Hashable, Sendable {
    case thirtySeconds  = "30s"
    case fiveMinutes    = "5m"
    case fortyFiveMinutes = "45m"

    var id: String { rawValue }
    var label: String { rawValue }

    /// Budget in seconds — consumed by `RunController` (Item 4c).
    var seconds: Int {
        switch self {
        case .thirtySeconds:    return 30
        case .fiveMinutes:      return 5 * 60
        case .fortyFiveMinutes: return 45 * 60
        }
    }
}

/// Per-case wall-clock budget. A `RunController` aborts (or truncates,
/// per `AbortPolicy`) a case that exceeds this. Bounded by Total budget
/// so we don't burn the whole 5-min window on one stuck case.
nonisolated enum PerCaseBudget: String, Identifiable, CaseIterable, Hashable, Sendable {
    case hundredMs  = "100ms"
    case oneSecond  = "1s"
    case fiveSeconds = "5s"

    var id: String { rawValue }
    var label: String { rawValue }

    /// Budget in seconds (fractional for sub-second values).
    var seconds: Double {
        switch self {
        case .hundredMs:   return 0.1
        case .oneSecond:   return 1.0
        case .fiveSeconds: return 5.0
        }
    }
}

/// Sample count per case (single-shot mode) — i.e. how many `invoke`
/// calls land in the latency histogram. Amortized mode auto-tunes K so
/// each loop runs ≥100 µs; this count is the *single-shot* sample
/// budget per `Runner.sampling` in spec §2.4.
nonisolated enum SampleCount: String, Identifiable, CaseIterable, Hashable, Sendable {
    case oneHundred  = "100"
    case fiveHundred = "500"
    case oneThousand = "1000"

    var id: String { rawValue }
    var label: String { rawValue }

    var count: Int {
        switch self {
        case .oneHundred:  return 100
        case .fiveHundred: return 500
        case .oneThousand: return 1000
        }
    }
}

/// Which sampling modes the run produces. `.shotOnly` is the smoke
/// default (per spec §2.4 — fast turnaround); `.loopOnly` is for
/// throughput-only sweeps (skip the latency tail data); `.both` is the
/// standard / full default.
nonisolated enum ModesSelection: String, Identifiable, CaseIterable, Hashable, Sendable {
    case shotOnly = "SHOT only"
    case loopOnly = "LOOP only"
    case both     = "Both"

    var id: String { rawValue }
    var label: String { rawValue }

    /// Lower to the `Set<Mode>` the row builder / chart consume.
    var asModes: Set<Mode> {
        switch self {
        case .shotOnly: return [.singleShot]
        case .loopOnly: return [.amortized]
        case .both:     return [.singleShot, .amortized]
        }
    }
}

/// Verification policy — spec §5 mandates an oracle for every dense FP
/// workload, so `.require` is the safe default. `.skip` is the explicit
/// opt-out for impls without an oracle (e.g. future Metal MPS cases
/// where no deterministic reference exists). When skipped, perf
/// numbers are still recorded but the verification badge is yellow.
nonisolated enum VerifyPolicy: String, Identifiable, CaseIterable, Hashable, Sendable {
    case require = "Require"
    case skip    = "Skip"

    var id: String { rawValue }
    var label: String { rawValue }
}

/// Per-case timeout policy. `.skipRemaining` is the safer default — a
/// runaway case shouldn't poison samples of cases it didn't reach.
/// `.truncateSamples` is for "give me whatever data you got" runs.
nonisolated enum AbortPolicy: String, Identifiable, CaseIterable, Hashable, Sendable {
    case skipRemaining   = "Skip remaining"
    case truncateSamples = "Truncate samples"

    var id: String { rawValue }
    var label: String { rawValue }
}

// MARK: - Vector size grid

/// The full log-spaced power-of-2 sweep called out in design doc §05
/// ("16 to 16M, log-spaced"). Pulled from the per-config use into a
/// shared constant so the modal's grid and any future presets/filters
/// reference the same list.
nonisolated enum VectorSizeCatalog {

    /// 21 powers of 2 from 16 (2^4) to 16M (2^24).
    static let all: [Int] = (4...24).map { 1 << $0 }

    /// `"1K"` / `"16M"` / `"512"` — abbreviates ≥1024 to K and ≥1M to M
    /// per the design doc's pill labels (`[16] [32] ... [1K] [2K] ...
    /// [16M]`).
    static func label(for n: Int) -> String {
        if n >= 1_048_576 {
            return "\(n / 1_048_576)M"
        }
        if n >= 1024 {
            return "\(n / 1024)K"
        }
        return "\(n)"
    }
}
