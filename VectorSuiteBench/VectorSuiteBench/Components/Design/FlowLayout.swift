import SwiftUI

/// Horizontally-wrapping flow layout. Used by the New Run modal's vector
/// sizes grid (design doc §05: "horizontally-wrapping pill grid at
/// log-spaced powers of 2"). Subviews lay out left-to-right; when one
/// won't fit, the layout wraps to the next row.
///
/// **Why not `LazyVGrid`.** A grid with fixed columns forces every cell
/// to the same width, which makes a row of `[16]` and `[1048576]` look
/// uneven (the 16 floats in dead space). A flow layout sizes each cell
/// to its content and wraps based on the actual width — closer to how a
/// CSS `flex-wrap: wrap` row reads.
///
/// **Limitation.** Honors `proposal.width` for wrap decisions; ignores
/// horizontal-alignment for the last row (left-aligned only). The pill
/// grid we ship here doesn't need centered or trailing alignment, so
/// adding a `HorizontalAlignment` parameter is deferred until a second
/// caller needs it.
struct FlowLayout: Layout {

    /// Horizontal gap between cells on the same row.
    var hSpacing: CGFloat = 6
    /// Vertical gap between rows.
    var vSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrangeRows(in: width, subviews: subviews)
        let totalHeight = rows.last.map { $0.y + $0.height } ?? 0
        let usedWidth = rows.map { $0.usedWidth }.max() ?? 0
        return CGSize(width: usedWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangeRows(in: bounds.width, subviews: subviews)
        for row in rows {
            for placement in row.placements {
                let view = subviews[placement.subviewIndex]
                view.place(
                    at: CGPoint(
                        x: bounds.minX + placement.x,
                        y: bounds.minY + row.y
                    ),
                    proposal: .unspecified
                )
            }
        }
    }

    // MARK: - Row arrangement

    /// One row of placed subviews + the row's vertical metrics.
    private struct Row {
        let placements: [SubviewPlacement]
        let y: CGFloat
        let height: CGFloat
        let usedWidth: CGFloat
    }

    private struct SubviewPlacement {
        let subviewIndex: Int
        let x: CGFloat
    }

    /// Pack subviews into rows that fit within `availableWidth`. Each
    /// row's `y` is the cumulative top offset; each subview's `x` is
    /// its left offset within its row.
    private func arrangeRows(in availableWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current: [SubviewPlacement] = []
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowY: CGFloat = 0

        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needsBreak = !current.isEmpty && x + size.width > availableWidth
            if needsBreak {
                rows.append(Row(
                    placements: current,
                    y: rowY,
                    height: rowHeight,
                    usedWidth: max(0, x - hSpacing)
                ))
                rowY += rowHeight + vSpacing
                x = 0
                rowHeight = 0
                current = []
            }
            current.append(SubviewPlacement(subviewIndex: i, x: x))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        if !current.isEmpty {
            rows.append(Row(
                placements: current,
                y: rowY,
                height: rowHeight,
                usedWidth: max(0, x - hSpacing)
            ))
        }
        return rows
    }
}
