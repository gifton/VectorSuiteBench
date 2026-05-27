import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit

/// Tests for the New Run modal's `RunConfig` model. Covers the
/// preset-defaults application, the touched-flips-to-custom invariant,
/// and the per-preset selection shapes from plan §3.
///
/// `@MainActor`-scoped because `RunConfig` is MainActor-isolated (UI
/// state container) — `@Suite(.serialized)` not needed because each
/// test constructs its own instance.
@MainActor
@Suite("RunConfig")
struct RunConfigTests {

    // MARK: - Initial state

    @Test("Default preset is smoke and the configuration matches smoke defaults")
    func defaultStateIsSmoke() {
        let c = RunConfig()
        #expect(c.preset == .smoke)
        #expect(c.ops == PresetSelection.smoke.defaultOps)
        #expect(c.impls == PresetSelection.smoke.defaultImpls)
        #expect(c.sizes == PresetSelection.smoke.defaultSizes)
        #expect(c.totalBudget == PresetSelection.smoke.defaultTotalBudget)
        #expect(c.perCaseBudget == PresetSelection.smoke.defaultPerCaseBudget)
        #expect(c.sampleCount == PresetSelection.smoke.defaultSampleCount)
        #expect(c.modes == PresetSelection.smoke.defaultModes)
    }

    // MARK: - Preset application

    @Test("selectPreset(.standard) applies the standard defaults")
    func selectStandardApplies() {
        let c = RunConfig()
        c.selectPreset(.standard)
        #expect(c.preset == .standard)
        #expect(c.ops == PresetSelection.standard.defaultOps)
        #expect(c.impls == PresetSelection.standard.defaultImpls)
        #expect(c.sizes == PresetSelection.standard.defaultSizes)
        #expect(c.modes == .both, Comment(rawValue: "standard preset measures both modes per plan §3"))
    }

    @Test("selectPreset(.full) applies the full defaults")
    func selectFullApplies() {
        let c = RunConfig()
        c.selectPreset(.full)
        #expect(c.preset == .full)
        #expect(c.totalBudget == .fortyFiveMinutes)
        #expect(c.sampleCount == .oneThousand)
    }

    @Test("selectPreset(.custom) keeps current selections; only label flips")
    func selectCustomPreservesSelections() {
        let c = RunConfig()
        c.selectPreset(.standard)
        let priorOps = c.ops
        let priorImpls = c.impls
        c.selectPreset(.custom)
        #expect(c.preset == .custom)
        #expect(c.ops == priorOps, Comment(rawValue: "custom must NOT override the user's current selection"))
        #expect(c.impls == priorImpls)
    }

    @Test("Re-selecting the current preset does not bounce off custom")
    func reselectingSamePresetIsStable() {
        let c = RunConfig()
        c.selectPreset(.smoke)
        #expect(c.preset == .smoke)
        c.selectPreset(.smoke)
        #expect(c.preset == .smoke, Comment(rawValue: "re-selecting smoke should not touch preset state"))
    }

    // MARK: - Touched → custom flip

    @Test("toggleOp flips preset to custom")
    func toggleOpFlipsToCustom() {
        let c = RunConfig()
        #expect(c.preset == .smoke)
        c.toggleOp(.axpy)
        #expect(c.preset == .custom)
        #expect(c.ops.contains(.axpy))
    }

    @Test("toggleImpl flips preset to custom")
    func toggleImplFlipsToCustom() {
        let c = RunConfig()
        c.toggleImpl(.simd)
        #expect(c.preset == .custom)
        #expect(c.impls.contains(.simd))
    }

    @Test("toggleSize flips preset to custom")
    func toggleSizeFlipsToCustom() {
        let c = RunConfig()
        c.toggleSize(2048)
        #expect(c.preset == .custom)
        #expect(c.sizes.contains(2048))
    }

    @Test("setTotalBudget flips preset to custom")
    func setTotalBudgetFlipsToCustom() {
        let c = RunConfig()
        c.setTotalBudget(.fortyFiveMinutes)
        #expect(c.preset == .custom)
        #expect(c.totalBudget == .fortyFiveMinutes)
    }

    @Test("setModes flips preset to custom and lowers correctly")
    func setModesFlipsAndLowers() {
        let c = RunConfig()
        c.setModes(.loopOnly)
        #expect(c.preset == .custom)
        #expect(c.modes == .loopOnly)
        #expect(c.modes.asModes == [.amortized])
    }

    @Test("Toggling an op off then back on still leaves preset as custom")
    func togglingTwiceIsStillCustom() {
        let c = RunConfig()
        c.toggleOp(.dot)       // remove (smoke has dot)
        c.toggleOp(.dot)       // add back
        #expect(c.preset == .custom, Comment(rawValue: "two toggles don't return to the original preset — only re-selecting via `selectPreset` does that"))
    }

    @Test("Custom selection survives every mutation type")
    func customSurvivesAllMutations() {
        let c = RunConfig()
        c.selectPreset(.custom)
        c.toggleOp(.cosine)
        c.toggleImpl(.naive)
        c.toggleSize(64)
        c.setTotalBudget(.fiveMinutes)
        c.setPerCaseBudget(.fiveSeconds)
        c.setSampleCount(.oneThousand)
        c.setModes(.shotOnly)
        c.setVerify(.skip)
        c.setAbortPolicy(.truncateSamples)
        #expect(c.preset == .custom)
    }

    // MARK: - PresetSelection defaults

    @Test("Smoke preset: small ops set, single VectorCore + Accelerate + naïve")
    func smokeDefaults() {
        let s = PresetSelection.smoke
        #expect(s.defaultOps == [.dot, .l2dist, .cosine])
        #expect(s.defaultImpls == [.vectorCore, .accelerate, .naive])
        #expect(s.defaultSizes == [512])
        #expect(s.defaultModes == .shotOnly, Comment(rawValue: "smoke is single-shot only per plan §3"))
        #expect(s.defaultTotalBudget == .thirtySeconds)
        #expect(s.defaultSampleCount == .oneHundred)
    }

    @Test("Standard preset: all ops minus null, all impls, both modes")
    func standardDefaults() {
        let s = PresetSelection.standard
        #expect(s.defaultOps == Set(OpKind.allCases).subtracting([.null]))
        #expect(s.defaultImpls == Set(ImplKind.allCases))
        #expect(s.defaultModes == .both)
        #expect(s.defaultTotalBudget == .fiveMinutes)
    }

    @Test("Full preset: 45-minute budget, 1000 samples")
    func fullDefaults() {
        let f = PresetSelection.full
        #expect(f.defaultTotalBudget == .fortyFiveMinutes)
        #expect(f.defaultSampleCount == .oneThousand)
        #expect(f.defaultModes == .both)
    }

    @Test("Verify policy defaults to Require for every preset (spec §5 mandate)")
    func verifyAlwaysRequire() {
        for p in PresetSelection.allCases {
            #expect(p.defaultVerify == .require,
                    Comment(rawValue: "preset \(p.label) must default to Require — spec §5 mandates an oracle for every dense FP workload"))
        }
    }

    // MARK: - VectorSizeCatalog

    @Test("VectorSizeCatalog.all has 21 powers of 2 from 16 to 16M")
    func sizeCatalogShape() {
        let all = VectorSizeCatalog.all
        #expect(all.count == 21)
        #expect(all.first == 16)
        #expect(all.last == 16 * 1024 * 1024)
        // Every entry should be a power of 2.
        for n in all {
            #expect(n > 0 && (n & (n - 1)) == 0,
                    Comment(rawValue: "\(n) is not a power of 2"))
        }
    }

    @Test("VectorSizeCatalog.label formats sub-K, K, and M sizes correctly")
    func sizeLabels() {
        #expect(VectorSizeCatalog.label(for: 16) == "16")
        #expect(VectorSizeCatalog.label(for: 512) == "512")
        #expect(VectorSizeCatalog.label(for: 1024) == "1K")
        #expect(VectorSizeCatalog.label(for: 4096) == "4K")
        #expect(VectorSizeCatalog.label(for: 1_048_576) == "1M")
        #expect(VectorSizeCatalog.label(for: 16 * 1_048_576) == "16M")
    }

    // MARK: - Budget enum lowering

    @Test("Budget enums lower to expected numeric values")
    func budgetLowering() {
        #expect(TotalBudget.thirtySeconds.seconds == 30)
        #expect(TotalBudget.fiveMinutes.seconds == 300)
        #expect(TotalBudget.fortyFiveMinutes.seconds == 2700)

        #expect(PerCaseBudget.hundredMs.seconds == 0.1)
        #expect(PerCaseBudget.oneSecond.seconds == 1.0)
        #expect(PerCaseBudget.fiveSeconds.seconds == 5.0)

        #expect(SampleCount.oneHundred.count == 100)
        #expect(SampleCount.oneThousand.count == 1000)
    }

    @Test("ModesSelection lowers to BenchKit-facing Set<Mode>")
    func modesLowering() {
        #expect(ModesSelection.shotOnly.asModes == [.singleShot])
        #expect(ModesSelection.loopOnly.asModes == [.amortized])
        #expect(ModesSelection.both.asModes == [.singleShot, .amortized])
    }

    // MARK: - OpKind.mathShorthand

    @Test("Every OpKind has a non-empty math shorthand (except the .null sentinel)")
    func mathShorthandTotal() {
        for op in OpKind.allCases {
            let s = op.mathShorthand
            if op == .null {
                #expect(s == "—")
            } else {
                #expect(!s.isEmpty,
                        Comment(rawValue: "OpKind.\(op.rawValue) has empty math shorthand"))
            }
        }
    }
}
