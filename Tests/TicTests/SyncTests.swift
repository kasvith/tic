import Foundation
import Testing
@testable import Tic

/// The sync rules (`SyncMerge`, pure) and a two-Mac round trip through real in-memory databases
/// (`AppDatabase.syncCycle`), with no files involved.
@Suite("Sync between Macs")
struct SyncTests {
    // MARK: - Helpers

    private func snapshot(_ device: String) -> SyncSnapshot { SyncSnapshot(device: device, name: device) }

    private func note(_ title: String, _ outline: [OutlineEntry] = [], synced: Bool = true) -> SyncLocal.NoteFields {
        .init(createdAt: 1, title: title, color: "yellow", material: "solid",
              hideCompleted: false, moveCompletedToBottom: false, outline: outline, isSynced: synced)
    }

    private func task(_ noteId: String, _ text: String, done: Bool = false) -> SyncLocal.TaskFields {
        .init(noteId: noteId, createdAt: 1, text: text, done: Completion(isDone: done, completedAt: done ? 5 : nil),
              image: nil)
    }

    private func syncTask(_ noteId: String, _ text: String, stamp: Int64) -> SyncTask {
        SyncTask(noteId: noteId, createdAt: 2, text: Register(value: text, stamp: stamp),
                 done: Register(value: Completion(isDone: false, completedAt: nil), stamp: stamp),
                 image: Register(value: nil, stamp: stamp))
    }

    private func entries(_ ids: String...) -> [OutlineEntry] { ids.map { OutlineEntry(id: $0, level: 0) } }

    /// One list "N" with tasks a, b recorded into a fresh snapshot at stamp 100.
    private func basic(_ device: String = "A") -> SyncSnapshot {
        var local = SyncLocal()
        local.notes["N"] = note("This week", entries("a", "b"))
        local.tasks["a"] = task("N", "Send slides")
        local.tasks["b"] = task("N", "Book train")
        return SyncMerge.record(local, into: snapshot(device), now: 100)
    }

    // MARK: - Record

    @Test("record stamps new lists and tasks, and recording again with no edits changes nothing")
    func recordNewThenQuiet() {
        let s = basic()
        #expect(s.notes["N"]?.title == Register(value: "This week", stamp: 100))
        #expect(s.tasks["b"]?.text.value == "Book train")
        #expect(s.clock == 100)

        let again = SyncMerge.record(SyncMerge.resolve(s), into: s, now: 200)
        #expect(again == s)
    }

    @Test("record stamps only the field that changed")
    func recordOneField() {
        let s = basic()
        var local = SyncMerge.resolve(s)
        local.tasks["a"]?.done = Completion(isDone: true, completedAt: 150)
        let next = SyncMerge.record(local, into: s, now: 150)
        #expect(next.tasks["a"]?.done.stamp == 150)
        #expect(next.tasks["a"]?.text.stamp == 100)
        #expect(next.notes["N"]?.title.stamp == 100)
    }

    @Test("a stamp is always above the highest seen, even when this Mac's clock is behind")
    func stampBeatsSlowClock() {
        var s = basic()
        s.clock = 5_000                     // seen a stamp from a Mac whose clock runs ahead
        var local = SyncMerge.resolve(s)
        local.notes["N"]?.title = "Next week"
        let next = SyncMerge.record(local, into: s, now: 200)
        #expect(next.notes["N"]?.title == Register(value: "Next week", stamp: 5_001))
    }

    @Test("a list or task missing from the database is marked deleted")
    func recordDelete() {
        let s = basic()
        var local = SyncMerge.resolve(s)
        local.tasks["b"] = nil
        local.notes["N"]?.outline = entries("a")
        let next = SyncMerge.record(local, into: s, now: 300)
        #expect(next.tasks["b"] == nil)
        #expect(next.deleted["b"] == 300)
    }

    // MARK: - Merge

    @Test("a tick on one Mac and a text edit on the other both survive")
    func fieldByField() {
        let base = basic()
        var work = SyncMerge.resolve(base)
        work.tasks["a"]?.done = Completion(isDone: true, completedAt: 200)
        var home = SyncMerge.resolve(base)
        home.tasks["a"]?.text = "Send slides to Sam"
        let w = SyncMerge.record(work, into: base, now: 200)
        let h = SyncMerge.record(home, into: { var s = base; s.device = "B"; return s }(), now: 300)

        let merged = SyncMerge.merge(w, h)
        #expect(merged.tasks["a"]?.text.value == "Send slides to Sam")
        #expect(merged.tasks["a"]?.done.value.isDone == true)
        #expect(merged.clock == 300)
    }

    @Test("merge is commutative and idempotent")
    func mergeLaws() {
        var a = basic("A")
        var b = basic("B")
        a.notes["N"]?.title = Register(value: "Work", stamp: 400)
        b.notes["N"]?.title = Register(value: "Home", stamp: 400)        // same millisecond
        b.tasks["c"] = syncTask("N", "Pay rent", stamp: 410)
        a.deleted["b"] = 420
        a.tasks["b"] = nil

        let ab = SyncMerge.merge(a, b), ba = SyncMerge.merge(b, a)
        #expect(ab.notes == ba.notes && ab.tasks == ba.tasks && ab.deleted == ba.deleted)
        #expect(SyncMerge.merge(ab, b).notes == ab.notes)
        #expect(SyncMerge.merge(ab, ab).tasks == ab.tasks)
    }

    @Test("the newer outline wins whole; a task only the other side has goes after its previous neighbour")
    func outlineMerge() {
        let work = Register(value: entries("essays", "slides", "plumber", "train"), stamp: 10)
        let home = Register(value: entries("train", "slides", "essays"), stamp: 20)
        let merged = SyncMerge.mergeOutline(work, home)
        #expect(merged.value.map(\.id) == ["train", "slides", "plumber", "essays"])
        #expect(merged.stamp == 20)
        #expect(SyncMerge.mergeOutline(home, work) == merged)
    }

    @Test("delete always wins, even over a newer edit")
    func deleteWins() {
        var work = basic("A")
        work.tasks["b"] = nil
        work.deleted["b"] = 200
        var home = basic("B")
        home.tasks["b"]?.text = Register(value: "Book train (keep?)", stamp: 900)
        #expect(SyncMerge.merge(work, home).tasks["b"] == nil)
        #expect(SyncMerge.merge(home, work).tasks["b"] == nil)
    }

    @Test("a task added to a list the other Mac deleted goes with the list")
    func orphanGoesWithList() {
        var work = basic("A")
        work.notes["N"] = nil
        work.tasks = [:]
        work.deleted = ["N": 200, "a": 200, "b": 200]
        var home = basic("B")
        home.tasks["c"] = syncTask("N", "New", stamp: 300)
        let merged = SyncMerge.merge(home, work)
        #expect(merged.notes.isEmpty && merged.tasks.isEmpty)
    }

    // MARK: - Resolve & changes

    @Test("resolve drops missing tasks from the outline, appends unmentioned ones and fixes nesting")
    func resolveOutline() {
        var s = basic()
        s.notes["N"]?.outline.value = [OutlineEntry(id: "gone", level: 0), OutlineEntry(id: "b", level: 2)]
        s.notes["N"]?.color.value = "ultraviolet"     // a value this build doesn't know
        let r = SyncMerge.resolve(s)
        #expect(r.notes["N"]?.outline == [OutlineEntry(id: "b", level: 0), OutlineEntry(id: "a", level: 0)])
        #expect(r.notes["N"]?.color == "yellow")
    }

    // MARK: - Two databases

    private func makeDB() throws -> AppDatabase { try AppDatabase.makeInMemory() }

    @Test("a list made on one Mac arrives on the other closed, with its tasks, ticks and nesting")
    func roundTrip() async throws {
        let work = try makeDB(), home = try makeDB()
        let list = try await work.insertNewNote(Note(title: "This week", color: .pink, isSynced: true))
        try await work.insertTask(TaskItem(noteId: list.id, text: "Send slides"))
        try await work.insertTask(
            TaskItem(noteId: list.id, text: "Draft", isDone: true, indentLevel: 1, completedAt: Date()))

        let w1 = try await work.syncCycle(mine: snapshot("A"), others: [], now: 1_000)
        let h1 = try await home.syncCycle(mine: snapshot("B"), others: [w1.snapshot], now: 2_000)
        #expect(h1.changes.insertedNotes == [list.id.uuidString])

        let arrived = try #require(try await home.note(id: list.id))
        #expect(arrived.title == "This week" && arrived.color == .pink)
        #expect(arrived.isOpen == false)
        let tasks = try await home.tasks(noteId: list.id)
        #expect(tasks.map(\.text) == ["Send slides", "Draft"])
        #expect(tasks.map(\.indentLevel) == [0, 1])
        #expect(tasks.map(\.isDone) == [false, true])

        // Nothing changed since: both sides are quiet.
        let w2 = try await work.syncCycle(mine: w1.snapshot, others: [h1.snapshot], now: 3_000)
        let h2 = try await home.syncCycle(mine: h1.snapshot, others: [w2.snapshot], now: 4_000)
        #expect(w2.changes.isEmpty && h2.changes.isEmpty)
        #expect(h2.snapshot.sameContent(as: h1.snapshot))
    }

    @Test("edits made on both Macs before a sync merge field by field; frames and open state stay put")
    func bothSidesEdit() async throws {
        let work = try makeDB(), home = try makeDB()
        let list = try await work.insertNewNote(Note(title: "This week", isSynced: true))
        try await work.insertTask(TaskItem(noteId: list.id, text: "Email Sam"))
        let w1 = try await work.syncCycle(mine: snapshot("A"), others: [], now: 1_000)
        let h1 = try await home.syncCycle(mine: snapshot("B"), others: [w1.snapshot], now: 2_000)

        var atWork = try #require(try await work.tasks(noteId: list.id).first)
        atWork.isDone = true
        atWork.completedAt = Date()
        try await work.update(atWork)
        try await work.updateNoteFrame(id: list.id, x: 900, y: 50, width: 300, height: 400)

        var atHome = try #require(try await home.tasks(noteId: list.id).first)
        atHome.text = "Email Sam about room 4"
        try await home.update(atHome)
        try await home.updateNoteOpen(id: list.id, isOpen: true)

        let w2 = try await work.syncCycle(mine: w1.snapshot, others: [h1.snapshot], now: 3_000)
        let h2 = try await home.syncCycle(mine: h1.snapshot, others: [w2.snapshot], now: 4_000)
        _ = try await work.syncCycle(mine: w2.snapshot, others: [h2.snapshot], now: 5_000)

        for db in [work, home] {
            let t = try #require(try await db.tasks(noteId: list.id).first)
            #expect(t.text == "Email Sam about room 4")
            #expect(t.isDone)
        }
        let homeNote = try #require(try await home.note(id: list.id))
        #expect(homeNote.frameX != 900 && homeNote.isOpen)
        let workNote = try #require(try await work.note(id: list.id))
        #expect(workNote.frameX == 900)
    }

    @Test("deleting a list on one Mac deletes it on the other")
    func deleteTravels() async throws {
        let work = try makeDB(), home = try makeDB()
        let list = try await work.insertNewNote(Note(title: "Old", isSynced: true))
        try await work.insertTask(TaskItem(noteId: list.id, text: "x"))
        let w1 = try await work.syncCycle(mine: snapshot("A"), others: [], now: 1_000)
        let h1 = try await home.syncCycle(mine: snapshot("B"), others: [w1.snapshot], now: 2_000)

        try await work.deleteNote(id: list.id)
        let w2 = try await work.syncCycle(mine: w1.snapshot, others: [h1.snapshot], now: 3_000)
        let h2 = try await home.syncCycle(mine: h1.snapshot, others: [w2.snapshot], now: 4_000)
        #expect(h2.changes.deletedNotes == [list.id.uuidString])
        #expect(try await home.allNotes().isEmpty)
        #expect(try await home.tasks(noteId: list.id).isEmpty)
    }
}

/// `FolderSync` end to end: real files in a temp folder standing in for iCloud Drive.
@MainActor
@Suite("Sync folder")
struct FolderSyncTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("tic-sync-\(UUID().uuidString)")

    private func mac(_ name: String, folder: URL) throws -> (AppDatabase, FolderSync) {
        let defaults = try #require(UserDefaults(suiteName: "tic-sync-test-\(UUID().uuidString)"))
        defaults.set(true, forKey: "syncEnabled")
        defaults.set(folder.path, forKey: "syncFolderPath")
        let db = try AppDatabase.makeInMemory()
        let state = root.appendingPathComponent("\(name)-state.json")
        return (db, FolderSync(database: db, stateURL: state, defaults: defaults, name: name))
    }

    @Test("two Macs sync through their own files in a shared folder")
    func throughFolder() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Tic")        // created on first sync: its parent exists
        let (workDB, work) = try mac("Work MacBook", folder: folder)
        let (homeDB, home) = try mac("Home iMac", folder: folder)

        let list = try await workDB.insertNewNote(Note(title: "This week", isSynced: true))
        try await workDB.insertTask(TaskItem(noteId: list.id, text: "Send slides"))
        await work.sync()
        await home.sync()

        #expect(try await homeDB.note(id: list.id)?.title == "This week")
        #expect(try await homeDB.tasks(noteId: list.id).map(\.text) == ["Send slides"])
        #expect(home.peers.map(\.name) == ["Work MacBook"])
        #expect(home.problem == nil && work.problem == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("devices").path)
        #expect(files.count == 2)
    }

    @Test("a Mac keeps its device id across launches, even when its state file is lost")
    func deviceIDPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "tic-sync-test-\(UUID().uuidString)"))
        let db = try AppDatabase.makeInMemory()
        let missing = root.appendingPathComponent("never-written.json")
        let first = FolderSync(database: db, stateURL: missing, defaults: defaults, name: "Mac")
        let relaunched = FolderSync(database: db, stateURL: missing, defaults: defaults, name: "Mac")
        #expect(first.deviceID == relaunched.deviceID)
        #expect(defaults.string(forKey: "syncDeviceID") == first.deviceID)
    }

    @Test("a folder whose parent is gone reads as unreachable instead of being recreated")
    func unreachable() async throws {
        let folder = root.appendingPathComponent("Unplugged Drive/Tic")
        let (_, sync) = try mac("Work MacBook", folder: folder)
        await sync.sync()
        #expect(sync.problem?.hasPrefix("Can't reach this folder") == true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("a file from a newer Tic is skipped with a hint to update")
    func newerSchema() async throws {
        let devices = root.appendingPathComponent("Tic/devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var future = SyncSnapshot(device: "FUTURE", name: "Home iMac")
        future.schema = SyncSnapshot.schemaVersion + 1
        future.sharing["N"] = Register(value: true, stamp: 1)
        future.notes["N"] = SyncNote(
            createdAt: 1, title: Register(value: "From the future", stamp: 1),
            color: Register(value: "yellow", stamp: 1),
            material: Register(value: "solid", stamp: 1), hideCompleted: Register(value: false, stamp: 1),
            moveCompletedToBottom: Register(value: false, stamp: 1), outline: Register(value: [], stamp: 1))
        try JSONEncoder().encode(future).write(to: devices.appendingPathComponent("FUTURE.json"))

        let (db, sync) = try mac("Work MacBook", folder: root.appendingPathComponent("Tic"))
        await sync.sync()
        #expect(try await db.allNotes().isEmpty)
        #expect(sync.problem?.contains("runs a newer Tic") == true)
    }
}
