import Foundation
import Testing
@testable import Tic

// MARK: - The simulated world

/// A wall clock shared by the simulated Macs (ms since 1970); each Mac may run ahead or behind it.
@MainActor
final class SimClock {
    var now: Int64 = 1_762_412_400_000   // 6 Nov 2026, 07:00 UTC
    func advance(minutes: Double) { now += Int64(minutes * 60_000) }
    func advance(ms: Int64) { now += ms }
}

/// One simulated Mac: its own in-memory database, settings, state file, `FolderSync`, and its *own*
/// copy of the sync folder on disk. Nothing moves between Macs until `SyncWorld.deliver` copies a
/// device file across, playing iCloud Drive, so a test can hold an upload back (the lid closed),
/// deliver late, or not at all. Its actions are the same database calls the UI makes
/// (`NoteController`'s add / toggle / move / delete paths through `TaskOutline`).
@MainActor
final class SimMac {
    let name: String
    let db: AppDatabase
    let folder: URL
    var clockOffset: Int64 = 0
    private(set) var sync: FolderSync!
    private let defaults: UserDefaults
    private let stateURL: URL
    private let clock: SimClock

    init(_ name: String, root: URL, clock: SimClock) throws {
        self.name = name
        self.clock = clock
        let home = root.appendingPathComponent(name, isDirectory: true)
        let drive = home.appendingPathComponent("iCloud Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        folder = drive.appendingPathComponent("Tic", isDirectory: true)   // FolderSync creates it
        stateURL = home.appendingPathComponent("sync-state.json")
        defaults = UserDefaults(suiteName: "tic-sim-\(UUID().uuidString)")!
        defaults.set(true, forKey: "syncEnabled")
        defaults.set(folder.path, forKey: "syncFolderPath")
        db = try AppDatabase.makeInMemory()
        launch()
    }

    /// A fresh `FolderSync` over the same settings and state file — what a relaunch of Tic does.
    func launch() {
        sync = FolderSync(database: db, stateURL: stateURL, defaults: defaults, name: name,
                          clock: { [unowned self] in self.clock.now + self.clockOffset })
    }

    /// One sync cycle, exactly as the app runs it.
    func syncNow() async { await sync.sync() }

    var ownFile: URL { folder.appendingPathComponent("devices/\(sync.deviceID).json") }

    // MARK: Actions (the UI's database paths)

    @discardableResult
    func newList(_ title: String) async throws -> UUID {
        try await db.insertNewNote(Note(title: title)).id
    }

    func tasks(_ list: UUID) async throws -> [TaskItem] { try await db.tasks(noteId: list) }

    @discardableResult
    func add(_ text: String, to list: UUID, level: Int = 0) async throws -> UUID {
        let tasks = try await tasks(list)
        let maxLevel = tasks.last.map { min(TaskItem.maxIndentLevel, $0.indentLevel + 1) } ?? 0
        let task = TaskItem(noteId: list, text: text, sortIndex: tasks.count, indentLevel: min(max(level, 0), maxLevel))
        try await db.insertTask(task)
        return task.id
    }

    func toggle(_ id: UUID, in list: UUID) async throws {
        let tasks = try await tasks(list)
        let updated = TaskOutline.applyingToggle(tasks, toggling: id, now: Date())
        try await db.updateTaskCompletion(TaskOutline.completionChanges(from: tasks, to: updated))
    }

    func edit(_ id: UUID, _ text: String) async throws {
        guard var task = try await db.task(id: id) else { return }
        task.text = text
        try await db.update(task)
    }

    func move(_ id: UUID, in list: UUID, to index: Int, level: Int? = nil) async throws {
        let tasks = try await tasks(list)
        let reordered = TaskOutline.movingSubtree(tasks, id: id, toInsertionIndex: index, targetLevel: level)
        guard reordered != tasks else { return }
        let normalized = TaskOutline.normalizedLevels(reordered)
        let levels = TaskOutline.indentLevelChanges(from: tasks, to: normalized).map { TaskLevelUpdate(id: $0.id, level: $0.level) }
        try await db.applyStructuralUpdate(reorder: normalized, levels: levels)
    }

    func delete(_ id: UUID, in list: UUID) async throws {
        let tasks = try await tasks(list)
        let survivors = TaskOutline.normalizedLevels(tasks.filter { $0.id != id })
        let levels = TaskOutline.indentLevelChanges(from: tasks, to: survivors).map { TaskLevelUpdate(id: $0.id, level: $0.level) }
        try await db.applyStructuralUpdate(deleteIds: [id], levels: levels)
    }

    func rename(_ list: UUID, _ title: String) async throws { try await db.updateNoteTitle(id: list, title: title) }

    func recolor(_ list: UUID, _ color: NoteColor) async throws {
        let material = try await db.note(id: list)?.material ?? .solid
        try await db.updateNoteAppearance(id: list, color: color, material: material)
    }

    func deleteList(_ list: UUID) async throws { try await db.deleteNote(id: list) }

    // MARK: Inspection

    /// Everything that syncs, as this Mac's database holds it.
    func synced() async throws -> SyncLocal { try await db.dbQueue.read { try AppDatabase.syncLocal($0) } }

    func texts(_ list: UUID) async throws -> [String] { try await tasks(list).map(\.text) }
}

/// A shared clock, some Macs, and a pretend iCloud Drive that copies their files around.
@MainActor
final class SyncWorld {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tic-sim-\(UUID().uuidString)")
    let clock = SimClock()
    private(set) var macs: [SimMac] = []

    func mac(_ name: String) throws -> SimMac {
        let mac = try SimMac(name, root: root, clock: clock)
        macs.append(mac)
        return mac
    }

    /// iCloud Drive moves `from`'s own file to `to`'s copy of the folder.
    func deliver(_ from: SimMac, to: SimMac) throws {
        guard let data = try? Data(contentsOf: from.ownFile) else { return }   // hasn't synced yet
        let devices = to.folder.appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try data.write(to: devices.appendingPathComponent(from.ownFile.lastPathComponent), options: .atomic)
    }

    func deliverAll() throws {
        for from in macs { for to in macs where to !== from { try deliver(from, to: to) } }
    }

    /// Sync, then deliver, every Mac in turn: a network with no delays. Two rounds, so the Macs that
    /// synced first also read what the later ones wrote.
    func syncAll(rounds: Int = 2) async throws {
        for _ in 0..<rounds {
            for mac in macs {
                await mac.syncNow()
                try deliverAll()
                clock.advance(ms: 1_000)
            }
        }
    }

    /// True when every Mac's database holds the same synced content.
    func converged() async throws -> Bool {
        var states: [SyncLocal] = []
        for mac in macs { states.append(try await mac.synced()) }
        return states.dropFirst().allSatisfy { $0 == states[0] }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - Scenarios

/// Two (or three) simulated Macs syncing through their own copies of a folder, end to end: real
/// files, real merges, real databases. Mirrors the use case sync was built for — a work laptop by day,
/// a home desktop in the evening — plus the ways it can go wrong.
@MainActor
@Suite("Sync simulation: two Macs")
struct SyncSimulationTests {

    @Test("a list made at work arrives at home closed, with its tasks, nesting and ticks")
    func arrives() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("This week")
        try await work.add("Send slides", to: list)
        let draft = try await work.add("Draft deck", to: list, level: 1)
        try await work.toggle(draft, in: list)

        await work.syncNow()
        let writtenAt = world.clock.now
        try world.deliver(work, to: home)
        world.clock.advance(minutes: 1)
        await home.syncNow()

        let note = try #require(try await home.db.note(id: list))
        #expect(note.title == "This week")
        #expect(note.isOpen == false)
        let tasks = try await home.tasks(list)
        #expect(tasks.map(\.text) == ["Send slides", "Draft deck"])
        #expect(tasks.map(\.indentLevel) == [0, 1])
        #expect(tasks.map(\.isDone) == [true, true])          // ticking the only child ticked its parent
        #expect(home.sync.peers.map(\.name) == ["Work MacBook"])
        #expect(home.sync.peers.first?.latestChange == Date(syncMillis: writtenAt))
        #expect(home.sync.problem == nil)
        #expect(try await world.converged())
    }

    @Test("a tick at home shows at work, cascade and all")
    func tickTravelsBack() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("This week")
        let parent = try await work.add("Trip", to: list)
        try await work.add("Book train", to: list, level: 1)
        try await work.add("Pack", to: list, level: 1)
        try await world.syncAll()

        try await home.toggle(parent, in: list)                 // ticks the whole subtree
        try await world.syncAll()

        #expect(try await work.tasks(list).map(\.isDone) == [true, true, true])
        #expect(try await world.converged())
    }

    @Test("edits made on both Macs before they sync merge field by field")
    func bothEditBeforeSyncing() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("This week")
        let email = try await work.add("Email Sam", to: list)
        try await world.syncAll()

        try await work.toggle(email, in: list)
        try await work.recolor(list, .pink)
        world.clock.advance(minutes: 5)
        try await home.edit(email, "Email Sam about room 4")
        try await home.rename(list, "This week (Nov)")
        try await world.syncAll(rounds: 2)

        for mac in world.macs {
            let task = try #require(try await mac.db.task(id: email))
            #expect(task.text == "Email Sam about room 4")
            #expect(task.isDone)
            let note = try #require(try await mac.db.note(id: list))
            #expect(note.title == "This week (Nov)")
            #expect(note.color == .pink)
        }
    }

    @Test("both Macs reorder: the later order wins whole, and a task added at work keeps its place")
    func bothReorder() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("This week")
        try await work.add("Mark essays", to: list)
        let slides = try await work.add("Send slides", to: list)
        let train = try await work.add("Book train", to: list)
        try await world.syncAll()
        _ = slides

        // Work, by day: adds "Call plumber" after "Send slides".
        let plumber = try await work.add("Call plumber", to: list)
        try await work.move(plumber, in: list, to: 2)
        #expect(try await work.texts(list) == ["Mark essays", "Send slides", "Call plumber", "Book train"])
        await work.syncNow()

        // Home, in the evening (before work's file arrives): "Book train" first, essays last.
        world.clock.advance(minutes: 120)
        try await home.move(train, in: list, to: 0)
        let essays = try #require(try await home.tasks(list).first { $0.text == "Mark essays" }).id
        try await home.move(essays, in: list, to: 3)
        #expect(try await home.texts(list) == ["Book train", "Send slides", "Mark essays"])
        await home.syncNow()

        try world.deliverAll()
        try await world.syncAll(rounds: 2)
        for mac in world.macs {
            #expect(try await mac.texts(list) == ["Book train", "Send slides", "Call plumber", "Mark essays"])
        }
    }

    @Test("a task deleted on one Mac stays deleted, even if the other edited it later")
    func deleteBeatsLaterEdit() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Reading")
        let old = try await work.add("Old reading list", to: list)
        try await work.add("Keep me", to: list)
        try await world.syncAll()

        try await work.delete(old, in: list)
        await work.syncNow()
        world.clock.advance(minutes: 60)
        try await home.edit(old, "Old reading list (keep?)")   // hasn't seen the delete yet
        await home.syncNow()
        try await world.syncAll(rounds: 2)

        for mac in world.macs {
            #expect(try await mac.db.task(id: old) == nil)
            #expect(try await mac.texts(list) == ["Keep me"])
        }
    }

    @Test("a list deleted at work takes with it a task added to it at home")
    func listDeletedWhileOtherAdds() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("Old project")
        try await work.add("a", to: list)
        let keep = try await work.newList("Keep")
        try await world.syncAll()

        try await work.deleteList(list)
        try await home.add("added at home", to: list)
        try await world.syncAll(rounds: 2)

        for mac in world.macs {
            #expect(try await mac.db.note(id: list) == nil)
            #expect(try await mac.tasks(list).isEmpty)
            #expect(try await mac.db.note(id: keep) != nil)
        }
    }

    @Test("the lid closes before the upload: nothing is lost and the newer edit still wins")
    func lidClosesBeforeUpload() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("This week")
        let train = try await work.add("Book train", to: list)
        try await world.syncAll()
        let lastDelivered = try #require(home.sync.peers.first?.latestChange)

        // 17:25 at work: a new task and a rename are written to disk, then the lid closes before
        // iCloud uploads the file.
        world.clock.advance(minutes: 60 * 10)
        try await work.add("Call plumber", to: list)
        try await work.rename(list, "This week (work)")
        await work.syncNow()
        let writtenAtWork = world.clock.now

        // 19:00 at home: nothing new has arrived, and Settings says so.
        world.clock.advance(minutes: 95)
        await home.syncNow()
        #expect(home.sync.peers.first?.latestChange == lastDelivered)
        #expect(try await home.texts(list) == ["Book train"])

        // 19:05: home keeps working, including a later rename of the same list.
        world.clock.advance(minutes: 5)
        try await home.toggle(train, in: list)
        try await home.rename(list, "This week (home)")
        await home.syncNow()

        // 08:00 next morning: the laptop wakes and the files finally move.
        world.clock.advance(minutes: 13 * 60)
        try world.deliverAll()
        try await world.syncAll(rounds: 2)

        for mac in world.macs {
            #expect(try await mac.texts(list) == ["Book train", "Call plumber"])
            #expect(try await mac.tasks(list).first?.isDone == true)
            #expect(try await mac.db.note(id: list)?.title == "This week (home)")   // 19:05 beats 17:25
        }
        // Settings now shows the morning: work's file changed again when it merged home's edits.
        #expect((home.sync.peers.first?.latestChange ?? .distantPast) > Date(syncMillis: writtenAtWork))
    }

    @Test("a Mac whose clock runs 10 minutes slow still wins with an edit made after seeing a change")
    func slowClock() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        home.clockOffset = -10 * 60_000
        let list = try await work.newList("Groceries")
        try await world.syncAll()

        try await work.rename(list, "Groceries (work)")
        await work.syncNow()
        try world.deliver(work, to: home)
        world.clock.advance(ms: 2_000)
        await home.syncNow()                                    // sees work's stamp, ahead of its clock
        #expect(try await home.db.note(id: list)?.title == "Groceries (work)")

        try await home.rename(list, "Groceries (home)")         // made after seeing work's rename
        await home.syncNow()
        try world.deliver(home, to: work)
        await work.syncNow()
        #expect(try await work.db.note(id: list)?.title == "Groceries (home)")
        #expect(try await world.converged())
    }

    @Test("where a list sits, whether it's open, rolled up or floating stay on each Mac")
    func perMacWindowState() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("This week")
        try await world.syncAll()
        try await home.db.updateNoteOpen(id: list, isOpen: true)
        let before = try #require(try await home.db.note(id: list))

        try await work.db.updateNoteFrame(id: list, x: 1_400, y: 900, width: 320, height: 500)
        try await work.db.updateNoteFlags(id: list, floatOnTop: true, showOnAllSpaces: true, isCollapsed: true)
        try await work.db.updateNoteOpen(id: list, isOpen: false)
        try await world.syncAll(rounds: 2)

        let after = try #require(try await home.db.note(id: list))
        #expect(after.frameX == before.frameX && after.frameW == before.frameW)
        #expect(after.isOpen && !after.floatOnTop && !after.showOnAllSpaces && !after.isCollapsed)
        #expect(try await work.db.note(id: list)?.isOpen == false)
    }

    @Test("once in step, more syncing writes nothing, and a relaunch picks up where it left off")
    func quietAndRelaunch() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("This week")
        try await work.add("a", to: list)
        try await home.add("b", to: try await home.newList("Home stuff"))
        try await world.syncAll(rounds: 2)

        let files = try world.macs.map { try Data(contentsOf: $0.ownFile) }
        let id = home.sync.deviceID
        try await world.syncAll(rounds: 2)
        home.launch()                                           // quit and reopen Tic at home
        await home.syncNow()
        #expect(try world.macs.map { try Data(contentsOf: $0.ownFile) } == files)
        #expect(home.sync.deviceID == id)
        #expect(home.sync.peers.map(\.name) == ["Work MacBook"])   // no ghost Mac
        #expect(try await world.converged())
    }

    @Test("a half-downloaded file is skipped, then read once it's whole")
    func halfDownloaded() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let work = try world.mac("Work MacBook"), home = try world.mac("Home iMac")
        let list = try await work.newList("This week")
        await work.syncNow()
        await home.syncNow()

        let full = try Data(contentsOf: work.ownFile)
        let devices = home.folder.appendingPathComponent("devices")
        try full.prefix(full.count / 2).write(to: devices.appendingPathComponent(work.ownFile.lastPathComponent))
        await home.syncNow()
        #expect(home.sync.problem == nil)
        #expect(try await home.db.note(id: list) == nil)

        try world.deliver(work, to: home)
        await home.syncNow()
        #expect(try await home.db.note(id: list) != nil)
    }

    @Test("three Macs converge whatever order they sync in")
    func threeMacs() async throws {
        let world = SyncWorld(); defer { world.cleanUp() }
        let a = try world.mac("Work MacBook"), b = try world.mac("Home iMac"), c = try world.mac("Old Mini")
        let list = try await a.newList("Shared")
        let t = try await a.add("one", to: list)
        try await world.syncAll()
        try await a.edit(t, "one (a)")
        try await b.add("two", to: list)
        try await c.toggle(t, in: list)
        for order in [[c, a, b], [b, c, a]] {
            for mac in order { await mac.syncNow(); try world.deliverAll() }
        }
        try await world.syncAll()
        #expect(try await world.converged())
        #expect(try await c.texts(list) == ["one (a)", "two"])
        #expect(try await c.tasks(list).first?.isDone == true)
    }
}

// MARK: - Random edits

/// A tiny seedable generator, so a failing random run can be replayed from its seed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
@Suite("Sync simulation: random edits")
struct SyncFuzzTests {
    /// Three Macs make random edits (add, tick, edit, reorder, re-nest, delete, rename, new and deleted
    /// lists, window moves), sync and deliver files at random, then settle. Afterwards every Mac must
    /// hold the same lists, nothing deleted anywhere may exist, nothing else may be lost, every outline
    /// must be valid, and syncing again must write nothing.
    @Test("random edits on three Macs, synced at random, always settle to the same lists", arguments: 0..<25)
    func randomEdits(seed: Int) async throws {
        var rng = SplitMix64(state: UInt64(seed) &* 7_919 &+ 1)
        let world = SyncWorld(); defer { world.cleanUp() }
        let macs = [try world.mac("Work MacBook"), try world.mac("Home iMac"), try world.mac("Old Mini")]
        var lists: [UUID] = []
        var listOf: [UUID: UUID] = [:]          // task → list, for every task ever made
        var deleted = Set<UUID>()               // every task or list any Mac deleted

        for step in 0..<40 {
            let mac = macs.randomElement(using: &rng)!
            let known = try await mac.db.allNotes().map(\.id)
            let list = known.randomElement(using: &rng)
            var tasks: [TaskItem] = []
            if let list { tasks = try await mac.tasks(list) }
            let task = tasks.randomElement(using: &rng)

            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<24:
                if let list {
                    let id = try await mac.add("t\(step)", to: list, level: Int.random(in: 0...2, using: &rng))
                    listOf[id] = list
                } else {
                    lists.append(try await mac.newList("L\(step)"))
                }
            case 24..<38:
                if let task, let list { try await mac.toggle(task.id, in: list) }
            case 38..<50:
                if let task { try await mac.edit(task.id, "e\(step)·\(mac.name)") }
            case 50..<62:
                if let task, let list {
                    let level: Int? = Bool.random(using: &rng) ? Int.random(in: 0...2, using: &rng) : nil
                    try await mac.move(task.id, in: list, to: Int.random(in: 0...tasks.count, using: &rng), level: level)
                }
            case 62..<70:
                if let task, let list { try await mac.delete(task.id, in: list); deleted.insert(task.id) }
            case 70..<75:
                if let list { try await mac.rename(list, "R\(step)") }
            case 75..<79:
                lists.append(try await mac.newList("L\(step)"))
            case 79..<81:
                if let list {
                    deleted.insert(list)
                    tasks.forEach { deleted.insert($0.id) }
                    try await mac.deleteList(list)
                }
            case 81..<86:
                if let list {
                    try await mac.db.updateNoteFrame(id: list, x: .random(in: 0...2_000, using: &rng), y: 100, width: 280, height: 360)
                    try await mac.db.updateNoteOpen(id: list, isOpen: Bool.random(using: &rng))
                }
            default:
                await mac.syncNow()
            }
            if Int.random(in: 0..<4, using: &rng) == 0 {
                let from = macs.randomElement(using: &rng)!, to = macs.randomElement(using: &rng)!
                if from !== to { try world.deliver(from, to: to) }
            }
            world.clock.advance(ms: Int64.random(in: 1...300_000, using: &rng))
        }

        try await world.syncAll(rounds: 3)
        let settled = try macs.map { try Data(contentsOf: $0.ownFile) }
        try await world.syncAll()

        #expect(try await world.converged(), "seed \(seed)")
        #expect(try macs.map { try Data(contentsOf: $0.ownFile) } == settled, "seed \(seed): still writing")
        let state = try await macs[0].synced()
        for id in deleted {
            #expect(state.notes[id.uuidString] == nil && state.tasks[id.uuidString] == nil, "seed \(seed): \(id) came back")
        }
        for list in lists where !deleted.contains(list) {
            #expect(state.notes[list.uuidString] != nil, "seed \(seed): list lost")
        }
        for (task, list) in listOf where !deleted.contains(task) && !deleted.contains(list) {
            #expect(state.tasks[task.uuidString] != nil, "seed \(seed): task lost")
        }
        for mac in macs {
            #expect(mac.sync.peers.count == 2 && mac.sync.problem == nil, "seed \(seed)")
            for note in try await mac.db.allNotes() {
                let levels = try await mac.tasks(note.id).map(\.indentLevel)
                #expect(levels.first ?? 0 == 0, "seed \(seed)")
                #expect(zip(levels, levels.dropFirst()).allSatisfy { $1 <= $0 + 1 && $1 <= TaskItem.maxIndentLevel },
                        "seed \(seed): invalid outline \(levels)")
            }
        }
    }
}
