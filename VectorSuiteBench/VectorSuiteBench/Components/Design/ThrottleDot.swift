import SwiftUI

/// Small indicator that lives in the top-right "throttle slot" of every
/// sidebar row (design doc §04 + §07). Three semantic states:
///
/// - `.none`          — slot is empty; row renders a clean shape.
/// - `.thermal(Int)`  — warn-colored dot indicating the OS reported a
///                      thermal escalation *during* the run. The count is
///                      announced via VoiceOver so a screen reader user
///                      gets the same triage signal a sighted user gets
///                      from the dot's presence.
/// - `.inflight`      — info-colored pulsing dot for runs still streaming
///                      from `RunController`. Per design doc §07 "Run still
///                      in progress" — single small spinning dot in the
///                      throttle slot. (Item 4c wires this up; current
///                      callers always pass `.none` or `.thermal`.)
///
/// **Defensive: `.thermal(0)` renders as `.none`.** Constructing the case
/// directly with a zero count is a foot-gun (callers may forget the
/// invariant), so the body switch normalizes it. The `init(escalations:)`
/// convenience already maps `<= 0` to `.none` — direct-case construction
/// gets the same safety net.
///
/// **Distinct from `VerificationDot`.** That atom signals per-case
/// numerical correctness; this one signals per-run thermal integrity.
/// They share the small-circle shape because both are read in the
/// "is this row trustworthy?" glance — keeping them separate atoms
/// keeps the semantics scannable in code search. Pulse animation lives
/// in the shared `PulseWhen` modifier so both atoms use identical
/// cadence.
struct ThrottleDot: View {
    let indicator: Indicator
    let size: CGFloat

    init(_ indicator: Indicator, size: CGFloat = 6) {
        self.indicator = indicator
        self.size = size
    }

    /// Convenience: derive state from a `RunSummary`'s thermal-escalation
    /// count. Threshold is `> 0` per design doc (any escalation surfaces
    /// the dot — there's no "small enough to ignore" amount for an engineer
    /// trying to triage a run).
    init(escalations: Int, size: CGFloat = 6) {
        self.init(escalations > 0 ? .thermal(escalations) : .none, size: size)
    }

    /// What the throttle slot displays. Named `Indicator` (not `State`) so
    /// it doesn't collide with `SwiftUI.State` in code-search and review;
    /// the slot's "state" lives in the parent row.
    enum Indicator: Hashable, Sendable {
        case none
        case thermal(Int)
        case inflight
    }

    var body: some View {
        Group {
            switch indicator {
            case .none:
                emptySlot
            case .thermal(let count) where count <= 0:
                // Defensive: caller constructed `.thermal(0)` directly.
                // Render as the empty slot rather than a confusing warn
                // dot with no underlying signal.
                emptySlot
            case .thermal(let count):
                Circle()
                    .fill(VSB.Status.warn)
                    .frame(width: size, height: size)
                    .accessibilityLabel(Text(
                        count == 1 ? "thermal throttle during run"
                                   : "\(count) thermal throttles during run"
                    ))
            case .inflight:
                Circle()
                    .fill(VSB.Status.info)
                    .frame(width: size, height: size)
                    .modifier(PulseWhen(active: true))
                    .accessibilityLabel(Text("run in progress"))
            }
        }
    }

    private var emptySlot: some View {
        Color.clear
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#Preview("ThrottleDot — all states") {
    HStack(spacing: 24) {
        VStack(spacing: 6) { ThrottleDot(.none);          Text("none").vsbMonoSha() }
        VStack(spacing: 6) { ThrottleDot(.thermal(1));    Text("thermal × 1").vsbMonoSha() }
        VStack(spacing: 6) { ThrottleDot(.thermal(4));    Text("thermal × 4").vsbMonoSha() }
        VStack(spacing: 6) { ThrottleDot(.inflight);      Text("inflight (pulses)").vsbMonoSha() }
        VStack(spacing: 6) { ThrottleDot(.thermal(0));    Text("thermal(0) → empty").vsbMonoSha() }
    }
    .padding(24)
    .background(VSB.Surface.bg)
}
