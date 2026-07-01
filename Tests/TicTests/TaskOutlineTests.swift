import Foundation
import Testing
@testable import Tic

@Suite("TaskOutline")
struct TaskOutlineTests {
    private let noteId = UUID()

    /// Builds a flat task list from `(text, indentLevel, isDone)` tuples, in order.
    private func make(_ specs: [(String, Int, Bool)]) -> [TaskItem] {
        specs.enumerated().map { i, spec in
            TaskItem(noteId: noteId, text: spec.0, isDone: spec.2, sortIndex: i, indentLevel: spec.1)
        }
    }

    private func done(_ tasks: [TaskItem]) -> [Bool] { tasks.map(\.isDone) }
    private func levels(_ tasks: [TaskItem]) -> [Int] { tasks.map(\.indentLevel) }

    // MARK: - Structure

    @Test("subtree spans a task and its deeper-nested descendants")
    func subtree() {
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 2, false), ("D", 0, false)])
        #expect(TaskOutline.subtreeRange(tasks, at: 0) == 0..<3)   // A + B + C
        #expect(TaskOutline.subtreeRange(tasks, at: 1) == 1..<3)   // B + C
        #expect(TaskOutline.subtreeRange(tasks, at: 2) == 2..<3)   // C alone
        #expect(TaskOutline.subtreeRange(tasks, at: 3) == 3..<4)   // D alone
    }

    @Test("parent + direct children skip grandchildren")
    func relationships() {
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 2, false), ("D", 1, false)])
        #expect(TaskOutline.parentIndex(tasks, of: 0) == nil)
        #expect(TaskOutline.parentIndex(tasks, of: 1) == 0)
        #expect(TaskOutline.parentIndex(tasks, of: 2) == 1)
        #expect(TaskOutline.parentIndex(tasks, of: 3) == 0)        // D's parent is A, not C
        #expect(TaskOutline.directChildren(tasks, of: 0) == [1, 3]) // B and D, not C
        #expect(TaskOutline.directChildren(tasks, of: 1) == [2])
    }

    // MARK: - Toggle cascade

    @Test("ticking a parent ticks its whole subtree")
    func toggleTopDown() {
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 2, false), ("D", 0, false)])
        let out = TaskOutline.applyingToggle(tasks, toggling: tasks[0].id, now: Date())
        #expect(done(out) == [true, true, true, false])           // A,B,C on; D untouched
        #expect(out[0].completedAt != nil)
        #expect(out[2].completedAt != nil)
    }

    @Test("finishing the last child auto-completes the parent (bubble up)")
    func toggleBubbleUp() {
        // B already done; ticking C should complete A automatically.
        let tasks = make([("A", 0, false), ("B", 1, true), ("C", 1, false), ("D", 0, false)])
        let out = TaskOutline.applyingToggle(tasks, toggling: tasks[2].id, now: Date())
        #expect(done(out) == [true, true, true, false])
    }

    @Test("reopening a child reopens its ancestors")
    func toggleUncheckBubble() {
        let tasks = make([("A", 0, true), ("B", 1, true), ("C", 2, true)])
        let out = TaskOutline.applyingToggle(tasks, toggling: tasks[2].id, now: Date())
        #expect(done(out) == [false, false, false])               // unticking C reopens B then A
        #expect(out.allSatisfy { $0.completedAt == nil })
    }

    @Test("a parent without all children done is not auto-completed")
    func toggleSiblingPartial() {
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 1, false)])
        let out = TaskOutline.applyingToggle(tasks, toggling: tasks[1].id, now: Date())
        #expect(done(out) == [false, true, false])                // only B; A stays open (C open)
    }

    @Test("toggle preserves an already-done task's completedAt timestamp")
    func togglePreservesTimestamp() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        var tasks = make([("A", 0, false), ("B", 1, true)])
        tasks[1].completedAt = stamp
        // Ticking A sets A done and (re)affirms B done — B was already done, so its stamp survives.
        let out = TaskOutline.applyingToggle(tasks, toggling: tasks[0].id, now: Date())
        #expect(out[1].completedAt == stamp)
    }

    // MARK: - Indent / outdent

    @Test("indent nests a task one level under the row above")
    func indent() {
        let tasks = make([("A", 0, false), ("B", 0, false)])
        let out = TaskOutline.indenting(tasks, id: tasks[1].id)
        #expect(levels(out) == [0, 1])
    }

    @Test("the first row cannot be indented")
    func indentFirstRowNoop() {
        let tasks = make([("A", 0, false), ("B", 0, false)])
        let out = TaskOutline.indenting(tasks, id: tasks[0].id)
        #expect(levels(out) == [0, 0])
    }

    @Test("an existing child cannot be indented past its parent")
    func indentChildNoop() {
        // B is already a direct child of A; nothing sits between them to become a deeper parent.
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 2, false)])
        let out = TaskOutline.indenting(tasks, id: tasks[1].id)
        #expect(levels(out) == [0, 1, 2])
    }

    @Test("indent carries the subtree and respects the 3-level cap")
    func indentCarriesSubtree() {
        // B is top-level with a nested subtree (C, D). Indenting B shifts the whole subtree down.
        let tasks = make([("A", 0, false), ("B", 0, false), ("C", 1, false), ("D", 2, false)])
        let out = TaskOutline.indenting(tasks, id: tasks[1].id)
        #expect(levels(out) == [0, 1, 2, 2])   // B 0→1, C 1→2, D 2→cap 2
        // Cannot indent B again — A above it is level 0, so 1 is already the deepest allowed.
        let again = TaskOutline.indenting(out, id: out[1].id)
        #expect(levels(again) == [0, 1, 2, 2])
    }

    @Test("outdent promotes a task and its subtree")
    func outdent() {
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 2, false)])
        let out = TaskOutline.outdenting(tasks, id: tasks[1].id)
        #expect(levels(out) == [0, 0, 1])   // B 1→0, C 2→1
    }

    @Test("outdent at top level is a no-op")
    func outdentTopLevelNoop() {
        let tasks = make([("A", 0, false), ("B", 1, false)])
        let out = TaskOutline.outdenting(tasks, id: tasks[0].id)
        #expect(levels(out) == [0, 1])
    }

    // MARK: - Normalisation

    @Test("normalize forces level 0 first and clamps jumps and the cap")
    func normalize() {
        let tasks = make([("A", 2, false), ("B", 2, false), ("C", 9, false)])
        let out = TaskOutline.normalizedLevels(tasks)
        #expect(levels(out) == [0, 1, 2])   // first→0, each at most prev+1, capped at 2
    }

    @Test("normalize repairs a jumped level left by a move")
    func normalizeOrphan() {
        // A level-2 row landing directly under a level-0 row (a +2 jump) must drop to a valid depth.
        let tasks = make([("A", 0, false), ("C", 2, false)])
        let out = TaskOutline.normalizedLevels(tasks)
        #expect(levels(out) == [0, 1])
    }

    // MARK: - Moving subtrees

    @Test("moving a parent carries its subtree")
    func moveCarriesSubtree() {
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 1, false), ("D", 0, false)])
        let out = TaskOutline.movingSubtree(tasks, id: tasks[0].id, toInsertionIndex: 4)
        #expect(out.map(\.text) == ["D", "A", "B", "C"])   // A's children follow A
        #expect(levels(out) == [0, 0, 1, 1])               // levels carried verbatim
    }

    @Test("moving a task carries nested grandchildren too")
    func moveCarriesGrandchildren() {
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 2, false), ("D", 0, false)])
        let out = TaskOutline.movingSubtree(tasks, id: tasks[1].id, toInsertionIndex: 4)
        #expect(out.map(\.text) == ["A", "D", "B", "C"])   // the whole B→C block moves
    }

    @Test("moving a leaf to the front reorders just that row")
    func moveLeafToFront() {
        let tasks = make([("A", 0, false), ("B", 0, false), ("C", 0, false)])
        let out = TaskOutline.movingSubtree(tasks, id: tasks[2].id, toInsertionIndex: 0)
        #expect(out.map(\.text) == ["C", "A", "B"])
    }

    @Test("moving with a target level re-nests the dragged row in place")
    func moveWithTargetLevel() {
        // Drag B onto the same spot but one level deeper → B nests under A.
        let tasks = make([("A", 0, false), ("B", 0, false), ("C", 0, false)])
        let out = TaskOutline.movingSubtree(tasks, id: tasks[1].id, toInsertionIndex: 1, targetLevel: 1)
        #expect(out.map(\.text) == ["A", "B", "C"])   // order unchanged
        #expect(levels(out) == [0, 1, 0])             // B re-nested under A
    }

    @Test("moving with a target level shifts the dragged subtree by the same delta")
    func moveSubtreeWithTargetLevel() {
        // B has child C; dragging B one level deeper carries C too (capped at 3 levels).
        let tasks = make([("A", 0, false), ("B", 0, false), ("C", 1, false)])
        let out = TaskOutline.movingSubtree(tasks, id: tasks[1].id, toInsertionIndex: 1, targetLevel: 1)
        #expect(out.map(\.text) == ["A", "B", "C"])
        #expect(levels(out) == [0, 1, 2])             // B 0→1, C 1→2
    }

    @Test("moving a ticked item (even when re-nesting) preserves every task's done state")
    func movePreservesDoneState() {
        // Drag the done item C to become a subtask of A — no tick state may change.
        let tasks = make([("A", 0, true), ("B", 0, false), ("C", 0, true)])
        let out = TaskOutline.movingSubtree(tasks, id: tasks[2].id, toInsertionIndex: 1, targetLevel: 1)
        #expect(out.first { $0.text == "A" }?.isDone == true)
        #expect(out.first { $0.text == "B" }?.isDone == false)
        #expect(out.first { $0.text == "C" }?.isDone == true)
    }

    @Test("normalizing levels preserves done state")
    func normalizePreservesDoneState() {
        let tasks = make([("A", 0, true), ("C", 2, true)])
        let out = TaskOutline.normalizedLevels(tasks)
        #expect(out.allSatisfy { $0.isDone })
    }

    @Test("moving a parent block into the middle keeps the subtree contiguous")
    func moveParentIntoMiddle() {
        // A is parent of B; C and D are top-level. Drop A's block between C and D (index 3).
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 0, false), ("D", 0, false)])
        let out = TaskOutline.movingSubtree(tasks, id: tasks[0].id, toInsertionIndex: 3)
        #expect(out.map(\.text) == ["C", "A", "B", "D"])
    }

    @Test("dropping a row between a parent and its children yields a valid outline after normalize")
    func moveBetweenParentAndChildren() {
        // Drop top-level D right after A (index 1). After normalize the result is still a valid
        // gap-free tree (B, C re-parent to D) — never an orphaned/jumped level.
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 1, false), ("D", 0, false)])
        let moved = TaskOutline.movingSubtree(tasks, id: tasks[3].id, toInsertionIndex: 1)
        #expect(moved.map(\.text) == ["A", "D", "B", "C"])
        let normalized = TaskOutline.normalizedLevels(moved)
        // valid outline invariant: first is 0, no level jumps more than +1.
        #expect(normalized[0].indentLevel == 0)
        #expect(zip(normalized, normalized.dropFirst()).allSatisfy { $1.indentLevel <= $0.indentLevel + 1 })
    }

    // MARK: - Level-change diff (what gets persisted)

    @Test("a drag that reorders AND re-nests still reports the re-nest as a level change")
    func levelChangesMatchById() {
        // The regression behind the bug: the new list is in a different order, so the level diff
        // must match by id — a positional diff would miss the re-nest and fail to persist it.
        let old = make([("A", 0, false), ("B", 0, false)])
        let moved = TaskOutline.normalizedLevels(
            TaskOutline.movingSubtree(old, id: old[1].id, toInsertionIndex: 1, targetLevel: 1)
        )
        let changes = TaskOutline.indentLevelChanges(from: old, to: moved)
        #expect(changes.count == 1)
        #expect(changes.first?.id == old[1].id)   // B
        #expect(changes.first?.level == 1)
    }

    @Test("a pure reorder reports no level changes")
    func levelChangesEmptyForPureReorder() {
        let old = make([("A", 0, false), ("B", 0, false)])
        let reordered = [old[1], old[0]]   // same items, swapped order, same levels
        #expect(TaskOutline.indentLevelChanges(from: old, to: reordered).isEmpty)
    }

    // MARK: - Sibling insertion (rapid-add continuation)

    @Test("sibling insertion lands just below a leaf at the same level")
    func siblingAfterLeaf() {
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 1, false)])
        let spot = TaskOutline.siblingInsertion(tasks, after: 1)   // after B
        #expect(spot?.index == 2)                                  // right before C
        #expect(spot?.level == 1)
    }

    @Test("sibling insertion lands below the whole subtree, not inside it")
    func siblingAfterSubtree() {
        // A has child B with grandchild C; A's next sibling goes after the entire A-block.
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 2, false), ("D", 0, false)])
        let spot = TaskOutline.siblingInsertion(tasks, after: 0)
        #expect(spot?.index == 3)                                  // before D, past B and C
        #expect(spot?.level == 0)
    }

    @Test("sibling insertion inherits the row's current (possibly indented) level")
    func siblingInheritsLevel() {
        // A mid-flow Shift-Tab leaves the row at level 2 → its sibling is also level 2.
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 2, false)])
        let spot = TaskOutline.siblingInsertion(tasks, after: 2)
        #expect(spot?.index == 3)
        #expect(spot?.level == 2)
    }

    @Test("sibling insertion is nil for an out-of-range index")
    func siblingOutOfRange() {
        let tasks = make([("A", 0, false)])
        #expect(TaskOutline.siblingInsertion(tasks, after: 5) == nil)
    }

    @Test("a sibling run builds downward in entry order and stays a valid outline")
    func siblingRunBuildsDownward() {
        var tasks = make([("P", 0, false), ("Existing", 1, false)])
        // The first new subtask under P lands at the bottom of P's subtree (after "Existing").
        let firstIdx = TaskOutline.subtreeRange(tasks, at: 0).upperBound
        tasks.insert(TaskItem(noteId: noteId, text: "S1", indentLevel: 1), at: firstIdx)
        // Each Return adds a sibling just below the row committed before it.
        var prevText = "S1"
        for name in ["S2", "S3"] {
            let prev = tasks.firstIndex { $0.text == prevText }!
            let spot = TaskOutline.siblingInsertion(tasks, after: prev)!
            tasks.insert(TaskItem(noteId: noteId, text: name, indentLevel: spot.level), at: spot.index)
            prevText = name
        }
        #expect(tasks.map(\.text) == ["P", "Existing", "S1", "S2", "S3"])
        #expect(levels(tasks) == [0, 1, 1, 1, 1])
        // The block is valid by construction — a normalize pass changes nothing.
        #expect(TaskOutline.normalizedLevels(tasks).map(\.indentLevel) == levels(tasks))
    }

    // MARK: - Display ordering (hide / move-completed-to-bottom)

    /// Asserts the outline invariant: first row is level 0 and no row is more than one deeper
    /// than the row above it.
    private func isValidOutline(_ tasks: [TaskItem]) -> Bool {
        guard let first = tasks.first else { return true }
        guard first.indentLevel == 0 else { return false }
        return zip(tasks, tasks.dropFirst()).allSatisfy { $1.indentLevel <= $0.indentLevel + 1 }
    }

    @Test("move-to-bottom sinks done top-level subtrees below not-done ones, stably")
    func sortCompletedTopLevel() {
        let tasks = make([("A", 0, false), ("B", 0, true), ("C", 0, false), ("D", 0, true)])
        let out = TaskOutline.sortedCompletedToBottom(tasks)
        #expect(out.map(\.text) == ["A", "C", "B", "D"])   // A,C keep order on top; B,D keep order below
        #expect(isValidOutline(out))
    }

    @Test("move-to-bottom recurses: a done child sinks below a not-done sibling under the same parent")
    func sortCompletedRecurses() {
        // P is not-done with a done child c1 and a not-done child c2.
        let tasks = make([("P", 0, false), ("c1", 1, true), ("c2", 1, false)])
        let out = TaskOutline.sortedCompletedToBottom(tasks)
        #expect(out.map(\.text) == ["P", "c2", "c1"])       // c2 rises above the done c1, P stays put
        #expect(isValidOutline(out))
    }

    @Test("move-to-bottom keeps a done subtree contiguous and preserves levels + timestamps")
    func sortCompletedKeepsSubtreeContiguous() {
        let stamp = Date(timeIntervalSince1970: 2_000)
        var tasks = make([("A", 0, false), ("B", 0, true), ("B1", 1, true), ("C", 0, false)])
        tasks[1].completedAt = stamp
        tasks[2].completedAt = stamp
        let out = TaskOutline.sortedCompletedToBottom(tasks)
        #expect(out.map(\.text) == ["A", "C", "B", "B1"])   // the whole done B-block sinks together
        #expect(levels(out) == [0, 0, 0, 1])                // levels carried verbatim
        #expect(out.first { $0.text == "B" }?.completedAt == stamp)
        #expect(out.first { $0.text == "B1" }?.completedAt == stamp)
        #expect(isValidOutline(out))
    }

    @Test("move-to-bottom is the identity when nothing is done, and on an empty list")
    func sortCompletedIdentity() {
        let tasks = make([("A", 0, false), ("B", 1, false), ("C", 0, false)])
        #expect(TaskOutline.sortedCompletedToBottom(tasks).map(\.text) == ["A", "B", "C"])
        #expect(TaskOutline.sortedCompletedToBottom([]).isEmpty)
    }

    @Test("hide-completed drops done rows and leaves a valid outline")
    func hideCompleted() {
        // A done parent B carries a done child B1 (both hidden); a not-done parent P keeps its
        // not-done child c2 but drops its done child c1.
        let tasks = make([
            ("A", 0, false), ("B", 0, true), ("B1", 1, true),
            ("P", 0, false), ("c1", 1, true), ("c2", 1, false),
        ])
        let out = TaskOutline.hidingCompleted(tasks)
        #expect(out.map(\.text) == ["A", "P", "c2"])
        #expect(out.allSatisfy { !$0.isDone })
        #expect(isValidOutline(out))
    }

    @Test("hide-completed on an all-done list yields an empty outline")
    func hideCompletedAllDone() {
        let tasks = make([("A", 0, true), ("B", 1, true)])
        #expect(TaskOutline.hidingCompleted(tasks).isEmpty)
    }
}
