import SwiftUI

/// Horizontal tab picker with an accent underline under the selected
/// option. Shared by the `Table ⟷ Charts` toggle in `RunDetailView` and
/// the five-slot chart picker in `ChartsPane` — both surfaces use the
/// same accent-bottom-border treatment + `VSB.accentSoft` selected fill,
/// so the chrome lives here in one place.
///
/// **Layout convention.** Items are left-aligned inside a `VSB.Surface.s0`
/// strip with a 1 px hair-line bottom (caller adds the `Divider` if it
/// needs one — keeps this view chrome-free at its trailing edge so it
/// composes cleanly with a body that might draw its own divider).
///
/// **Label is caller-supplied** so the picker doesn't bake in label
/// styling. The closure receives `(item, isSelected)` so the caller can
/// flip text/icon color per state — typically `VSB.Impl.vectorCore` on
/// the selected one and `VSB.Text.md` on the rest.
struct UnderlineTabPicker<Item: Hashable & Identifiable, Label: View>: View {

    let items: [Item]
    @Binding var selection: Item

    /// Per-item label builder. `isSelected` is computed by the picker and
    /// passed in so the caller doesn't have to re-derive it from the
    /// binding.
    let label: (Item, Bool) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                tab(for: item)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .background(VSB.Surface.s0)
    }

    private func tab(for item: Item) -> some View {
        let isSelected = item == selection
        return Button {
            selection = item
        } label: {
            label(item, isSelected)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? VSB.accentSoft : Color.clear)
                .overlay(
                    Rectangle()
                        .fill(isSelected ? VSB.Impl.vectorCore : Color.clear)
                        .frame(height: 1),
                    alignment: .bottom
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
