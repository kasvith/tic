import SwiftUI

/// A docked note's tab: at rest a thin sliver in its colour against the display edge; hovered, the window slides
/// out to the full tab with the list's count, icon and sideways name (Settings › General › Docked tabs picks
/// which), fading in as it widens. A click opens the note, a drag moves the tab along the edge or pulls the note
/// off (`NoteWindowManager`, Edge dock).
struct DockTabView: View {
    let controller: NoteController
    /// Always the solid paper theme: a tab is drawn on paper, whatever the note's material.
    let theme: NoteTheme

    private var note: Note { controller.note }
    private var style: DockTabStyle { controller.dockTabStyle }
    private var edge: DockEdge { controller.tabEdge }
    private var title: String {
        controller.isCovered ? "Private" : (note.title.isEmpty ? "Untitled List" : note.title)
    }

    var body: some View {
        let shape = Self.shape(edge)
        GeometryReader { geo in
            VStack(spacing: 5) {
                if style == .titleCount, !controller.isCovered { count }
                if !controller.isCovered, let icon = NoteIcon(stored: note.icon) {
                    NoteIconView(icon: icon, ink: theme.title).font(.system(size: 13))
                }
                SidewaysText(text: title, edge: edge).foregroundStyle(theme.title)
            }
            .padding(.vertical, 9)
            .frame(width: DockLayout.maxTabWidth, height: geo.size.height, alignment: .top)
            // Fades in as the sliver widens into the tab.
            .opacity(min(max((geo.size.width - DockLayout.sliverWidth) / (DockLayout.maxTabWidth - DockLayout.sliverWidth), 0), 1))
            .frame(width: geo.size.width, alignment: edge == .right ? .leading : .trailing)
            .clipped()
        }
        .background(shape.fill(theme.fill))
        .overlay(shape.stroke(Color.black.opacity(0.14), lineWidth: 0.5))
        // On top, so every press reaches it: a click opens the note, a drag moves the tab or pulls the note off, and a
        // right-click offers the same without opening it first.
        .overlay(WindowMoveArea(onClick: { controller.onTabClick?() }, contextMenu: menu))
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open") { controller.onTabClick?() })
        menu.addItem(ClosureMenuItem("Undock") { controller.onToggleDock?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close List") { controller.requestClose() })
        return menu
    }

    @ViewBuilder private var count: some View {
        let remaining = controller.tasks.filter { !$0.isDone }.count
        if remaining > 0 {
            Text("\(remaining)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(theme.accent))
        }
    }

    /// Rounded on the side away from the edge, square against it.
    static func shape(_ edge: DockEdge) -> UnevenRoundedRectangle {
        let r: CGFloat = 6
        return edge == .right
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 0, topTrailingRadius: 0)
            : UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r, topTrailingRadius: r)
    }
}

/// A one-line label turned to run down the tab: top to bottom on the right edge, bottom to top on the left,
/// starting near the top either way.
private struct SidewaysText: View {
    let text: String
    let edge: DockEdge

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: geo.size.height, height: geo.size.width, alignment: edge == .right ? .leading : .trailing)
                .rotationEffect(.degrees(edge == .right ? 90 : -90))
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
