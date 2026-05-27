import SwiftUI
import BenchKit

/// Small trailing-toolbar chip that telegraphs whether the harness is
/// busy. Design doc §04 calls for "a green dot when idle, the machine
/// model, and the core count — so an engineer kicking off runs over SSH
/// can see at a glance whether the harness is busy."
///
/// **State source.** Until Item 4c wires `RunController` in-process, the
/// app has no live "running" state — the only way runs land today is
/// via the CLI, which the app doesn't observe. The chip therefore
/// renders `.idle` permanently in 2.1; the `LiveState` enum is the seam
/// Item 4c flips through when streaming a run.
///
/// **Hardware text** reuses `RunSummaryFormatters.hardwareHeadline`
/// (the same `"M3 Max · 14C / 30G"` rendering used by the
/// `RunSummaryHeader`'s Hardware cell) so the toolbar and the per-run
/// header read identically.
struct LiveStateChip: View {

    let state: LiveState
    let hardware: HardwareInventory

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(RunSummaryFormatters.hardwareHeadline(for: hardware))
                .vsbMonoSha()
        }
        .help(state.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(state.accessibilityState). \(hardware.chip), \(hardware.pCoreCount + hardware.eCoreCount) CPU cores, \(hardware.gpuCoreCount) GPU cores."))
    }
}

/// Harness liveness states surfaced by the toolbar chip. Color mapping
/// uses the existing `VSB.Status.*` tokens so the chip reads against the
/// same palette as the verification dot and the thermal banner.
///
/// **`nonisolated`** — same pattern as `VerificationDisplayState`. Pure
/// value enum; only `var color` is MainActor (it reads `VSB.Status.*`).
nonisolated enum LiveState: Hashable, Sendable {
    /// No run in flight. Green dot. Default state.
    case idle
    /// A run is currently being measured (Item 4c will drive this when
    /// `RunController` runs in-process).
    case running
    /// The most recent run ended in a verification failure (Item 4c
    /// surface). Distinct from idle because the chip is the only place
    /// in the chrome that surfaces "last run was bad" at a glance.
    case failed

    @MainActor var color: Color {
        switch self {
        case .idle:    return VSB.Status.pass
        case .running: return VSB.Status.info
        case .failed:  return VSB.Status.fail
        }
    }

    /// macOS-native tooltip text. Surfaces on hover via `.help(_:)`.
    var helpText: String {
        switch self {
        case .idle:    return "Harness idle — ready to start a run"
        case .running: return "Run in progress"
        case .failed:  return "Last run ended in verification failure"
        }
    }

    /// VoiceOver phrasing for the state portion of the chip's label.
    /// Combined with hardware info in the full label.
    var accessibilityState: String {
        switch self {
        case .idle:    return "Harness idle"
        case .running: return "Run in progress"
        case .failed:  return "Last run failed"
        }
    }
}

#Preview("LiveStateChip — all states") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach([LiveState.idle, .running, .failed], id: \.self) { state in
            LiveStateChip(
                state: state,
                hardware: HardwareInventory(
                    chip: "Apple M3 Max",
                    pCoreCount: 12, eCoreCount: 4,
                    gpuCoreCount: 30, memoryGB: 36,
                    osVersion: "26.2", xcodeBuild: "26B12",
                    swiftVersion: "6.0+"
                )
            )
        }
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
