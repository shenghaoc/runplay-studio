import SwiftUI

/// Pins a workspace root to the size of the window's detail column.
///
/// Without this, a workspace whose content has a large ideal height — the
/// Trends chart panels, the Personal Heatmap map surface — reports that ideal
/// height to the enclosing `NavigationSplitView`, the detail column inflates
/// past the window, and the overflow is centred. It is then the *top* that is
/// cut off, taking the workspace header and filter bar with it, with no way to
/// scroll them back. Both workspaces shipped that way (#109, #110); the
/// measured ideal height was roughly 1,020 pt in each, independent of the
/// window's width.
///
/// `GeometryReader` is what makes this work, and not only as a way to read the
/// size: it has no ideal size of its own, so it stops the content's ideal
/// height from reaching the split view at all. The definite frame then
/// proposes exactly the column's size to the workspace, whose own
/// `maxHeight: .infinity` expands it to fill and lets its flexible child — a
/// scroll view, a map — absorb the difference.
///
/// Applied once, to the detail column in `ContentView`, so that every
/// workspace gets it and a workspace added later cannot forget it.
private struct FillsWorkspaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .top
                )
        }
    }
}

extension View {
    /// Constrains a workspace to the window instead of letting its ideal
    /// height inflate the `NavigationSplitView` detail column.
    func fillsWorkspace() -> some View {
        modifier(FillsWorkspaceModifier())
    }
}
