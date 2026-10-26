import AppKit
import SwiftUI

// The reorder drag's state and visuals, driven by `NoteView`'s reorder gesture.

/// The in-flight reorder drag. A reference type so the per-frame pointer position re-renders only the
/// lifted row that reads it; the list reads just which task, slot and level — a few changes per drag.
@MainActor @Observable
final class ReorderDrag {
    /// The dragged task followed by its subtree, as displayed at pickup; empty when no drag is in flight.
    var block: [TaskItem] = []
    /// Where `block` sat in the displayed list at pickup.
    var blockRange: Range<Int> = 0..<0
    /// Insertion index into the displayed list *without* the block: where the placeholder sits.
    var slot = 0
    /// The level the block's head will land at.
    var level = 0
    /// The head row's frame and the pointer at pickup, in list coordinates.
    var startFrame: CGRect = .zero
    var startLocation: CGPoint = .zero
    /// The live pointer, written every frame.
    var location: CGPoint = .zero

    var taskID: TaskItem.ID? { block.first?.id }

    /// Top of the lifted row: it keeps the pointer where it grabbed the row, but is one line tall.
    var liftedTop: CGFloat {
        location.y - min(max(startLocation.y - startFrame.minY, 0), LiftedRow.height)
    }
}

/// The dragged task floating under the pointer — a raised card with the grip and, for a parent, a
/// "+N" for the subtasks riding along. Its own view, so following the pointer re-renders just this.
struct LiftedRow: View {
    static let height: CGFloat = 24

    let drag: ReorderDrag
    let task: TaskItem
    let theme: NoteTheme
    @State private var renderCache = MarkdownRenderCache()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let carried = drag.block.count - 1
        HStack(spacing: 8) {
            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(task.isDone ? theme.checkbox : theme.secondary)
            Text(renderCache.rendered(
                text: task.text.isEmpty ? "Image" : task.text,
                color: task.isDone ? theme.completed : theme.task
            ))
            .lineLimit(1)
            Spacer(minLength: 0)
            if carried > 0 {
                Text("+\(carried)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.task)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(theme.accent.opacity(0.22)))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height - 2)
        .background {
            Group {
                if theme.isGlass {
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                } else {
                    shape.fill(theme.fill).overlay(shape.fill(.white.opacity(0.3)))
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 10, y: 6)
            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
        }
        .overlay(alignment: .leading) {
            GripDots().fill(theme.secondary.opacity(0.8)).frame(width: 6, height: 10).offset(x: -3)
        }
        .scaleEffect(1.02)
        .padding(.leading, leading)
        .padding(.trailing, NoteLayout.rowInset - 6)
        .frame(width: drag.startFrame.width, alignment: .leading)
        .offset(x: drag.startFrame.minX, y: drag.liftedTop + 1)
    }

    /// The card's left edge follows the pointer sideways within the indent range while its right edge
    /// stays put, so it never runs off the note.
    private var leading: CGFloat {
        let start = NoteLayout.rowInset - 6 + CGFloat(task.indentLevel) * NoteLayout.indentStep
        let deepest = NoteLayout.rowInset - 6 + CGFloat(TaskItem.maxIndentLevel + 1) * NoteLayout.indentStep
        return min(max(start + drag.location.x - drag.startLocation.x, 2), deepest)
    }
}

/// Where the dragged task will land: a ghost of it — faded text in a dashed, theme-tinted slot — at the
/// level it will drop to. One line tall whatever the task's size, so the list barely shifts.
struct DropPlaceholder: View {
    let task: TaskItem
    /// Subtasks riding along with it.
    let carried: Int
    let level: Int
    let theme: NoteTheme
    @State private var renderCache = MarkdownRenderCache()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(theme.secondary)
            Text(renderCache.rendered(
                text: (task.text.isEmpty ? "Image" : task.text) + (carried > 0 ? "  +\(carried)" : ""),
                color: theme.task
            ))
            .lineLimit(1)
            .opacity(0.5)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: LiftedRow.height - 2)
        .background(shape.fill(theme.accent.opacity(0.08)))
        .overlay(shape.strokeBorder(theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .padding(.leading, CGFloat(level) * NoteLayout.indentStep)
        .padding(.horizontal, -6)
    }
}

/// An elbow: down from (`x`, `top`) to `bottom`, then right to `endX`. Animatable, so it glides with
/// the placeholder instead of jumping when the drop target changes.
struct DropThread: Shape, Equatable {
    var x: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var endX: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(x, top), AnimatablePair(bottom, endX)) }
        set {
            (x, top) = (newValue.first.first, newValue.first.second)
            (bottom, endX) = (newValue.second.first, newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        let radius = max(0, min(5, bottom - top, endX - x))
        var path = Path()
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: x + radius, y: bottom), control: CGPoint(x: x, y: bottom))
        path.addLine(to: CGPoint(x: endX, y: bottom))
        return path
    }
}
