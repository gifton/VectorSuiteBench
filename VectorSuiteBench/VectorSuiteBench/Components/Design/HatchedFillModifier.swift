import SwiftUI

/// Overlays a 45° diagonal-line pattern on the modified view. Used by:
/// - `ImplSwatch` when `isApproximate == true` — the 10×10 swatch becomes
///   visibly "lighter" than a solid bar.
/// - `ThroughputBarChart` bar marks for approximate-class rows — the bar
///   keeps its color but gains the texture.
///
/// Pattern spec from the design doc §02: 45° lines, 5 px pitch, 1 px stroke
/// in `Color.white.opacity(0.25)`. The hatch sits ABOVE the fill (not
/// replacing it) so the underlying color still carries the impl identity.
///
/// `active: false` is a no-op so call sites can write
/// `.modifier(HatchedFillModifier(active: isApprox))` unconditionally.
struct HatchedFillModifier: ViewModifier {
    let active: Bool
    var strokeColor: Color = .white.opacity(0.25)
    var pitch: CGFloat = 5

    func body(content: Content) -> some View {
        if active {
            content.overlay(HatchPattern(strokeColor: strokeColor, pitch: pitch))
        } else {
            content
        }
    }
}

/// Tile-able diagonal hatching. Sized to its container; covers any
/// rectangle by walking offsets from `-diagonal` to `+diagonal`.
private struct HatchPattern: View {
    let strokeColor: Color
    let pitch: CGFloat

    var body: some View {
        Canvas { context, size in
            let diagonal = (size.width * size.width + size.height * size.height).squareRoot()
            let count = Int(diagonal / pitch) + 2
            for i in -count...count {
                let offset = CGFloat(i) * pitch
                var path = Path()
                path.move(to: CGPoint(x: offset, y: -diagonal))
                path.addLine(to: CGPoint(x: offset + diagonal, y: diagonal))
                context.stroke(path, with: .color(strokeColor), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("HatchedFillModifier") {
    HStack(spacing: 20) {
        Rectangle()
            .fill(VSB.Impl.vectorCore)
            .frame(width: 80, height: 80)
            .modifier(HatchedFillModifier(active: false))
        Rectangle()
            .fill(VSB.Impl.vectorCore)
            .frame(width: 80, height: 80)
            .modifier(HatchedFillModifier(active: true))
    }
    .padding()
    .background(VSB.Surface.bg)
}
