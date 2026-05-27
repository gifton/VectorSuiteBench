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
/// **Caching.** SwiftUI calls `sizeThatFits` and `placeSubviews`
/// separately per layout cycle, and `arrangeRows` is the expensive
/// part (one `sizeThatFits` call per subview). We use the `Layout`
/// protocol's `Cache` to share the row arrangement between the two
/// calls when the proposed width + subview count haven't changed.
/// At the New Run modal's 21 size pills this saves 21 sizeThatFits
/// calls per render; matters more as future callers (chart legends,
/// chip filters) might hand us larger collections.
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

    // MARK: - Cache

    /// `Layout.Cache` associated type. Explicit `typealias` because
    /// nesting a type literally named `Cache` doesn't let Swift infer
    /// the protocol requirement (the protocol's nested type and the
    /// struct collide). Optional so the initial `makeCache` can return
    /// `nil` — caller fills it on the first arrangement.
    typealias Cache = ArrangedRows?

    /// Cached row arrangement. Invalidated when the proposal width or
    /// the subview count changes — both common reasons for a fresh
    /// layout pass. Spacing parameters are layout-instance properties,
    /// so any change to those produces a different `FlowLayout`
    /// instance and SwiftUI's framework hands us a fresh cache.
    struct ArrangedRows {
        var width: CGFloat
        var subviewCount: Int
        var rows: [Row]
        var totalSize: CGSize
    }

    func makeCache(subviews: Subviews) -> Cache { nil }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        if let existing = cache, existing.subviewCount != subviews.count {
            cache = nil
        }
    }

    // MARK: - Layout protocol

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrangedCache(for: width, subviews: subviews, cache: &cache).totalSize
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let entry = arrangedCache(for: bounds.width, subviews: subviews, cache: &cache)
        for row in entry.rows {
            for placement in row.placements {
                subviews[placement.subviewIndex].place(
                    at: CGPoint(
                        x: bounds.minX + placement.x,
                        y: bounds.minY + row.y
                    ),
                    proposal: .unspecified
                )
            }
        }
    }

    // MARK: - Row arrangement (with cache)

    /// Return the cached arrangement if it matches `width` + the
    /// current subview count; otherwise compute, cache, and return.
    private func arrangedCache(
        for width: CGFloat,
        subviews: Subviews,
        cache: inout Cache
    ) -> ArrangedRows {
        if let existing = cache,
           existing.width == width,
           existing.subviewCount == subviews.count {
            return existing
        }
        let entry = arrangeRows(in: width, subviews: subviews)
        cache = entry
        return entry
    }

    /// One row of placed subviews + the row's vertical metrics.
    struct Row {
        let placements: [SubviewPlacement]
        let y: CGFloat
        let height: CGFloat
        let usedWidth: CGFloat
    }

    struct SubviewPlacement {
        let subviewIndex: Int
        let x: CGFloat
    }

    /// Pack subviews into rows that fit within `availableWidth`. Each
    /// row's `y` is the cumulative top offset; each subview's `x` is
    /// its left offset within its row.
    private func arrangeRows(in availableWidth: CGFloat, subviews: Subviews) -> ArrangedRows {
        var rows: [Row] = []
        var current: [SubviewPlacement] = []
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowY: CGFloat = 0
        var maxRowWidth: CGFloat = 0

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
                maxRowWidth = max(maxRowWidth, max(0, x - hSpacing))
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
            maxRowWidth = max(maxRowWidth, max(0, x - hSpacing))
        }
        let totalHeight = rows.last.map { $0.y + $0.height } ?? 0
        return ArrangedRows(
            width: availableWidth,
            subviewCount: subviews.count,
            rows: rows,
            totalSize: CGSize(width: maxRowWidth, height: totalHeight)
        )
    }
}
