import Foundation

/// The pure maths of sync between Macs (no AppKit, no DB, no files), kept apart like `TaskOutline`
/// so every rule is unit-tested in isolation:
///
/// - `record` stamps what changed in this Mac's database since its last snapshot (the export).
/// - `merge` folds another Mac's snapshot in: newest stamp wins per field, delete always wins, a
///   note's outline is one value. Commutative and idempotent, so file order and repeats don't matter.
/// - `resolve` says what a snapshot means for the database, and `changes` diffs that against what the
///   database holds, so a cycle writes only what differs.
enum SyncMerge {

    // MARK: - Record (export)

    /// Stamps every synced field whose database value differs from what `snapshot` resolves to, adds
    /// new notes/tasks, and marks missing ones deleted. Comparing against `resolve(snapshot)` (not the
    /// raw registers) means a value this Mac had to adjust on apply — a normalised outline, an
    /// unreadable colour — isn't mistaken for a local edit.
    static func record(_ local: SyncLocal, into snapshot: SyncSnapshot, now: Int64) -> SyncSnapshot {
        var s = snapshot
        let base = resolve(snapshot)
        let stamp = max(now, s.clock + 1)
        var changed = false

        func set<V>(_ register: inout Register<V>, to value: V, was old: V) {
            guard value != old else { return }
            register = Register(value: value, stamp: stamp)
            changed = true
        }

        for (id, n) in local.notes where s.deleted[id] == nil {
            guard var note = s.notes[id], let old = base.notes[id] else {
                s.notes[id] = SyncNote(
                    createdAt: n.createdAt,
                    title: Register(value: n.title, stamp: stamp),
                    color: Register(value: n.color, stamp: stamp),
                    material: Register(value: n.material, stamp: stamp),
                    hideCompleted: Register(value: n.hideCompleted, stamp: stamp),
                    moveCompletedToBottom: Register(value: n.moveCompletedToBottom, stamp: stamp),
                    outline: Register(value: n.outline, stamp: stamp)
                )
                changed = true
                continue
            }
            set(&note.title, to: n.title, was: old.title)
            set(&note.color, to: n.color, was: old.color)
            set(&note.material, to: n.material, was: old.material)
            set(&note.hideCompleted, to: n.hideCompleted, was: old.hideCompleted)
            set(&note.moveCompletedToBottom, to: n.moveCompletedToBottom, was: old.moveCompletedToBottom)
            set(&note.outline, to: n.outline, was: old.outline)
            s.notes[id] = note
        }

        for (id, t) in local.tasks where s.deleted[id] == nil && s.deleted[t.noteId] == nil {
            guard var task = s.tasks[id], let old = base.tasks[id] else {
                s.tasks[id] = SyncTask(
                    noteId: t.noteId, createdAt: t.createdAt,
                    text: Register(value: t.text, stamp: stamp),
                    done: Register(value: t.done, stamp: stamp)
                )
                changed = true
                continue
            }
            set(&task.text, to: t.text, was: old.text)
            set(&task.done, to: t.done, was: old.done)
            s.tasks[id] = task
        }

        for id in Array(s.notes.keys) where local.notes[id] == nil {
            s.notes[id] = nil
            s.deleted[id] = stamp
            changed = true
        }
        for id in Array(s.tasks.keys) where local.tasks[id] == nil {
            s.tasks[id] = nil
            s.deleted[id] = stamp
            changed = true
        }

        if changed { s.clock = stamp }
        return s
    }

    // MARK: - Merge

    /// Folds `other` into `mine`, keeping `mine`'s identity (device, name, writtenAt).
    static func merge(_ mine: SyncSnapshot, _ other: SyncSnapshot) -> SyncSnapshot {
        var out = mine
        out.clock = max(mine.clock, other.clock)

        for (id, stamp) in other.deleted { out.deleted[id] = max(out.deleted[id] ?? stamp, stamp) }
        for id in out.deleted.keys {
            out.notes[id] = nil
            out.tasks[id] = nil
        }

        for (id, theirs) in other.notes where out.deleted[id] == nil {
            out.notes[id] = out.notes[id].map { merge($0, theirs) } ?? theirs
        }
        for (id, theirs) in other.tasks where out.deleted[id] == nil {
            out.tasks[id] = out.tasks[id].map { merge($0, theirs) } ?? theirs
        }

        // A task added on one Mac to a list deleted on the other goes with its list.
        out.tasks = out.tasks.filter { out.notes[$0.value.noteId] != nil }
        return out
    }

    static func merge(_ a: SyncNote, _ b: SyncNote) -> SyncNote {
        SyncNote(
            createdAt: min(a.createdAt, b.createdAt),
            title: pick(a.title, b.title),
            color: pick(a.color, b.color),
            material: pick(a.material, b.material),
            hideCompleted: pick(a.hideCompleted, b.hideCompleted),
            moveCompletedToBottom: pick(a.moveCompletedToBottom, b.moveCompletedToBottom),
            outline: mergeOutline(a.outline, b.outline)
        )
    }

    static func merge(_ a: SyncTask, _ b: SyncTask) -> SyncTask {
        SyncTask(noteId: a.noteId, createdAt: min(a.createdAt, b.createdAt),
                 text: pick(a.text, b.text), done: pick(a.done, b.done))
    }

    /// Newest stamp wins. Equal stamps with different values (two Macs, same millisecond) fall back to
    /// comparing the encoded values, so every Mac picks the same winner.
    static func pick<V>(_ a: Register<V>, _ b: Register<V>) -> Register<V> {
        wins(a, over: b) ? a : b
    }

    private static func wins<V>(_ a: Register<V>, over b: Register<V>) -> Bool {
        if a.stamp != b.stamp { return a.stamp > b.stamp }
        if a.value == b.value { return true }
        return !encoded(a.value).lexicographicallyPrecedes(encoded(b.value))
    }

    private static func encoded<V: Encodable>(_ value: V) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode([value])) ?? Data()
    }

    /// The newest outline wins whole; a task only the other outline has is kept, placed after its
    /// previous neighbour there (or first, if it has none). The result keeps the winner's stamp.
    static func mergeOutline(_ a: Register<[OutlineEntry]>, _ b: Register<[OutlineEntry]>) -> Register<[OutlineEntry]> {
        let (winner, loser) = wins(a, over: b) ? (a, b) : (b, a)
        var result = winner.value
        var present = Set(result.map(\.id))
        for (i, entry) in loser.value.enumerated() where !present.contains(entry.id) {
            var at = 0
            for j in stride(from: i - 1, through: 0, by: -1) {
                if let k = result.firstIndex(where: { $0.id == loser.value[j].id }) { at = k + 1; break }
            }
            result.insert(entry, at: at)
            present.insert(entry.id)
        }
        return Register(value: result, stamp: winner.stamp)
    }

    // MARK: - Resolve

    /// What `snapshot` means for the database: values a database can hold (an unknown colour falls
    /// back), tasks only under live notes, and each outline cleaned up — entries for missing tasks
    /// dropped, tasks it doesn't mention appended (oldest first), nesting normalised.
    static func resolve(_ snapshot: SyncSnapshot) -> SyncLocal {
        var out = SyncLocal()
        var members: [String: Set<String>] = [:]
        for (id, t) in snapshot.tasks where snapshot.notes[t.noteId] != nil {
            out.tasks[id] = SyncLocal.TaskFields(noteId: t.noteId, createdAt: t.createdAt,
                                                 text: t.text.value, done: t.done.value)
            members[t.noteId, default: []].insert(id)
        }
        for (id, n) in snapshot.notes {
            out.notes[id] = SyncLocal.NoteFields(
                createdAt: n.createdAt,
                title: n.title.value,
                color: (NoteColor(rawValue: n.color.value) ?? .yellow).rawValue,
                material: (NoteMaterial(rawValue: n.material.value) ?? .solid).rawValue,
                hideCompleted: n.hideCompleted.value,
                moveCompletedToBottom: n.moveCompletedToBottom.value,
                outline: effectiveOutline(n.outline.value, members: members[id] ?? [], tasks: out.tasks)
            )
        }
        return out
    }

    static func effectiveOutline(
        _ outline: [OutlineEntry], members: Set<String>, tasks: [String: SyncLocal.TaskFields]
    ) -> [OutlineEntry] {
        var seen = Set<String>()
        var list = outline.filter { members.contains($0.id) && seen.insert($0.id).inserted }
        let created = { (id: String) in tasks[id]?.createdAt ?? 0 }
        list += members.subtracting(seen)
            .sorted { (created($0), $0) < (created($1), $1) }
            .map { OutlineEntry(id: $0, level: 0) }
        // The one outline rule, shared with the UI: first row level 0, never more than one deeper.
        let placeholder = UUID()
        let levels = TaskOutline.normalizedLevels(list.map { TaskItem(noteId: placeholder, indentLevel: $0.level) })
        return zip(list, levels).map { OutlineEntry(id: $0.id, level: $1.indentLevel) }
    }

    // MARK: - Changes

    /// The writes that turn `old` (the database) into `new` (a resolved snapshot). Tasks of a deleted
    /// note aren't listed: the foreign-key cascade removes them with it.
    static func changes(from old: SyncLocal, to new: SyncLocal) -> SyncChanges {
        var c = SyncChanges()
        for id in old.notes.keys where new.notes[id] == nil { c.deletedNotes.append(id) }
        for (id, t) in old.tasks where new.tasks[id] == nil && new.notes[t.noteId] != nil {
            c.deletedTasks.append(id)
        }
        for (id, n) in new.notes {
            guard let o = old.notes[id] else {
                c.insertedNotes.append(id)
                c.outlines.append(id)
                continue
            }
            if o.title != n.title || o.color != n.color || o.material != n.material
                || o.hideCompleted != n.hideCompleted || o.moveCompletedToBottom != n.moveCompletedToBottom {
                c.updatedNotes.append(id)
            }
            if o.outline != n.outline { c.outlines.append(id) }
        }
        for (id, t) in new.tasks {
            guard let o = old.tasks[id] else { c.insertedTasks.append(id); continue }
            if o.text != t.text || o.done != t.done { c.updatedTasks.append(id) }
        }
        c.deletedNotes.sort(); c.deletedTasks.sort(); c.insertedNotes.sort(); c.updatedNotes.sort()
        c.insertedTasks.sort(); c.updatedTasks.sort(); c.outlines.sort()
        return c
    }
}
