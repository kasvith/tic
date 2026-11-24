import CoreGraphics
import Foundation
import MCP
import Testing
@testable import Tic

/// The MCP tool dispatcher end to end over an in-memory database — the same path a real agent drives,
/// minus the socket. Window pokes are captured so we can assert the tools ask for the right ones.
@Suite("MCP tools")
struct MCPToolsTests {
    /// A tools instance plus a record of every window action it requested.
    @MainActor
    final class Harness {
        let db: AppDatabase
        let tools: MCPTools
        var opened: [UUID] = []
        var closed: [UUID] = []
        var framed: [(UUID, CGRect)] = []
        var focused: [UUID] = []

        init() throws {
            let db = try AppDatabase.makeInMemory()
            self.db = db
            let box = Box()
            self.tools = MCPTools(database: db, window: .init(
                open: { id in await box.record { $0.opened.append(id) } },
                close: { id in await box.record { $0.closed.append(id) } },
                setFrame: { id, r in await box.record { $0.framed.append((id, r)) } },
                focus: { id in await box.record { $0.focused.append(id) } }
            ))
            box.harness = self
        }

        // Bridges the tools' @Sendable off-actor closures back onto this @MainActor record.
        final class Box: @unchecked Sendable {
            weak var harness: Harness?
            func record(_ mutate: @escaping @MainActor (Harness) -> Void) async {
                await MainActor.run { if let h = harness { mutate(h) } }
            }
        }
    }

    private func call(_ tools: MCPTools, _ name: String, _ args: [String: Value]) async -> (Value, Bool) {
        let result = await tools.call(name, args)
        let text = result.content.first.flatMap { if case let .text(t, _, _) = $0 { return t } else { return nil } } ?? ""
        let value = (try? JSONDecoder().decode(Value.self, from: Data(text.utf8))) ?? .string(text)
        return (value, result.isError ?? false)
    }

    @Test("create_note seeds an outline, get_note reads it back, and the panel is opened")
    @MainActor func createAndRead() async throws {
        let h = try Harness()
        let (created, err) = await call(h.tools, "create_note", [
            "title": "Groceries",
            "color": "blue",
            "tasks": .array([
                .string("Produce"),
                .object(["text": "Apples", "level": 1]),
                .object(["text": "Milk", "level": 5]),   // over-deep → clamped to a valid outline
            ]),
        ])
        #expect(!err)
        let id = try #require(created.objectValue?["note_id"]?.stringValue ?? created.objectValue?["id"]?.stringValue)
        #expect(h.opened.map(\.uuidString) == [id])

        let (note, err2) = await call(h.tools, "get_note", ["note_id": .string(id)])
        #expect(!err2)
        let tasks = try #require(note.objectValue?["tasks"]?.arrayValue)
        #expect(tasks.map { $0.objectValue?["text"]?.stringValue } == ["Produce", "Apples", "Milk"])
        #expect(tasks.map { $0.objectValue?["level"]?.intValue } == [0, 1, 2])   // 5 clamped to 2, still ≤ prev+1
        #expect(note.objectValue?["color"]?.stringValue == "blue")
    }

    @Test("update_task done cascades to the whole subtree")
    @MainActor func doneCascade() async throws {
        let h = try Harness()
        let (created, _) = await call(h.tools, "create_note", ["title": "P",
            "tasks": .array([.string("Parent"), .object(["text": "A", "level": 1]), .object(["text": "B", "level": 1])])])
        let noteId = try #require(created.objectValue?["id"]?.stringValue)
        let (note, _) = await call(h.tools, "get_note", ["note_id": .string(noteId)])
        let tasks = try #require(note.objectValue?["tasks"]?.arrayValue)
        let parentId = try #require(tasks[0].objectValue?["id"]?.stringValue)

        let (_, err) = await call(h.tools, "update_task", ["task_id": .string(parentId), "done": true])
        #expect(!err)
        let (after, _) = await call(h.tools, "get_note", ["note_id": .string(noteId)])
        let doneStates = try #require(after.objectValue?["tasks"]?.arrayValue).map { $0.objectValue?["done"]?.boolValue }
        #expect(doneStates == [true, true, true])   // parent tick cascaded to both children
    }

    @Test("move_task re-nests a row and preserves ticks")
    @MainActor func moveReNest() async throws {
        let h = try Harness()
        let (created, _) = await call(h.tools, "create_note", ["title": "M",
            "tasks": .array([.string("One"), .string("Two")])])
        let noteId = try #require(created.objectValue?["id"]?.stringValue)
        let (note, _) = await call(h.tools, "get_note", ["note_id": .string(noteId)])
        let tasks = try #require(note.objectValue?["tasks"]?.arrayValue)
        let secondId = try #require(tasks[1].objectValue?["id"]?.stringValue)
        _ = await call(h.tools, "update_task", ["task_id": .string(secondId), "done": true])

        let (_, err) = await call(h.tools, "move_task", ["task_id": .string(secondId), "level": 1])
        #expect(!err)
        let (after, _) = await call(h.tools, "get_note", ["note_id": .string(noteId)])
        let rows = try #require(after.objectValue?["tasks"]?.arrayValue)
        #expect(rows[1].objectValue?["level"]?.intValue == 1)    // now a subtask of "One"
        #expect(rows[1].objectValue?["done"]?.boolValue == true) // structural move kept the tick
    }

    @Test("update_note changes colour and title and asks to bring the note forward")
    @MainActor func updateNoteRoundTrip() async throws {
        let h = try Harness()
        let (created, _) = await call(h.tools, "create_note", ["title": "Old"])
        let id = try #require(created.objectValue?["id"]?.stringValue)
        h.opened.removeAll()

        let (updated, err) = await call(h.tools, "update_note",
            ["note_id": .string(id), "title": "New", "color": "pink", "collapsed": true, "open": true])
        #expect(!err)
        #expect(updated.objectValue?["title"]?.stringValue == "New")
        #expect(updated.objectValue?["color"]?.stringValue == "pink")
        #expect(updated.objectValue?["collapsed"]?.boolValue == true)
        #expect(h.opened.map(\.uuidString) == [id])
    }

    @Test("update_note sets an icon and Private, an empty icon removes it, and a bad icon is a tool error")
    @MainActor func iconAndPrivate() async throws {
        let h = try Harness()
        let (created, _) = await call(h.tools, "create_note", ["title": "Groceries", "icon": "🛒"])
        let id = try #require(created.objectValue?["id"]?.stringValue)
        #expect(created.objectValue?["icon"]?.stringValue == "🛒")
        #expect(created.objectValue?["private"]?.boolValue == false)

        let (updated, err) = await call(h.tools, "update_note",
            ["note_id": .string(id), "icon": "symbol:cart", "private": true])
        #expect(!err)
        #expect(updated.objectValue?["icon"]?.stringValue == "symbol:cart")
        #expect(updated.objectValue?["private"]?.boolValue == true)

        let (cleared, _) = await call(h.tools, "update_note", ["note_id": .string(id), "icon": ""])
        #expect(cleared.objectValue?["icon"] == .null)

        let (_, badErr) = await call(h.tools, "update_note", ["note_id": .string(id), "icon": "symbol:rocket.ship"])
        #expect(badErr)
    }

    @Test("move_note persists the frame via the window action")
    @MainActor func moveNoteAction() async throws {
        let h = try Harness()
        let (created, _) = await call(h.tools, "create_note", ["title": "F"])
        let id = try #require(created.objectValue?["id"]?.stringValue)

        let (frameRes, err) = await call(h.tools, "move_note",
            ["note_id": .string(id), "x": 400.0, "y": 300.0, "width": 320.0, "height": 400.0])
        #expect(!err)
        let fx = frameRes.objectValue?["frame"]?.objectValue?["x"]
        #expect((fx?.doubleValue ?? fx?.intValue.map(Double.init)) == 400)
        #expect(h.framed.count == 1)
        #expect(h.framed.first?.1 == CGRect(x: 400, y: 300, width: 320, height: 400))
    }

    @Test("clear_completed and delete_tasks remove rows and re-level survivors")
    @MainActor func removals() async throws {
        let h = try Harness()
        let (created, _) = await call(h.tools, "create_note", ["title": "R",
            "tasks": .array([.string("Keep"), .string("Drop"), .string("Done")])])
        let noteId = try #require(created.objectValue?["id"]?.stringValue)
        var (note, _) = await call(h.tools, "get_note", ["note_id": .string(noteId)])
        var tasks = try #require(note.objectValue?["tasks"]?.arrayValue)
        let dropId = try #require(tasks[1].objectValue?["id"]?.stringValue)
        let doneId = try #require(tasks[2].objectValue?["id"]?.stringValue)

        _ = await call(h.tools, "update_task", ["task_id": .string(doneId), "done": true])
        let (cleared, e1) = await call(h.tools, "clear_completed", ["note_id": .string(noteId)])
        #expect(!e1 && cleared.objectValue?["cleared"]?.intValue == 1)
        let (deleted, e2) = await call(h.tools, "delete_tasks", ["task_ids": .array([.string(dropId)])])
        #expect(!e2 && deleted.objectValue?["deleted"]?.intValue == 1)

        (note, _) = await call(h.tools, "get_note", ["note_id": .string(noteId)])
        tasks = try #require(note.objectValue?["tasks"]?.arrayValue)
        #expect(tasks.map { $0.objectValue?["text"]?.stringValue } == ["Keep"])
    }

    @Test("bad ids and unknown tools are tool errors, not crashes")
    @MainActor func errors() async throws {
        let h = try Harness()
        let (_, e1) = await call(h.tools, "get_note", ["note_id": "not-a-uuid"])
        #expect(e1)
        let (_, e2) = await call(h.tools, "get_note", ["note_id": .string(UUID().uuidString)])
        #expect(e2)   // well-formed id, no such note
        let (_, e3) = await call(h.tools, "nonsense", [:])
        #expect(e3)
        let (_, e4) = await call(h.tools, "create_note", ["color": "chartreuse"])
        #expect(e4)   // unknown colour
    }

    // A valid 1x1 transparent PNG, base64.
    private static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    @Test("set/crop/remove image round-trips, and get_note reports has_image")
    @MainActor func imageTools() async throws {
        let h = try Harness()
        let (created, _) = await call(h.tools, "create_note", ["title": "Pics", "tasks": .array([.string("Shot")])])
        let noteId = try #require(created.objectValue?["id"]?.stringValue)
        let (note, _) = await call(h.tools, "get_note", ["note_id": .string(noteId)])
        let taskId = try #require(note.objectValue?["tasks"]?.arrayValue?[0].objectValue?["id"]?.stringValue)

        let (_, e1) = await call(h.tools, "set_task_image", ["task_id": .string(taskId), "data": .string(Self.pngBase64)])
        #expect(!e1)
        var (after, _) = await call(h.tools, "get_note", ["note_id": .string(noteId)])
        #expect(after.objectValue?["tasks"]?.arrayValue?[0].objectValue?["has_image"]?.boolValue == true)

        // Crop out of range is clamped, not rejected.
        let (cropRes, e2) = await call(h.tools, "crop_task_image",
            ["task_id": .string(taskId), "x": 0.5, "y": 0.5, "width": 0.9, "height": 0.9])
        #expect(!e2)
        func num(_ v: Value?) -> Double? { v?.doubleValue ?? v?.intValue.map(Double.init) }
        #expect(num(cropRes.objectValue?["crop"]?.objectValue?["width"]) == 0.9)   // requested size kept
        #expect(abs((num(cropRes.objectValue?["crop"]?.objectValue?["x"]) ?? 0) - 0.1) < 0.0001)  // x shifted to stay in bounds

        let (rmRes, e3) = await call(h.tools, "remove_task_image", ["task_id": .string(taskId)])
        #expect(!e3)
        #expect(rmRes.objectValue?["deleted_task"]?.boolValue == false)      // task has text → kept
        (after, _) = await call(h.tools, "get_note", ["note_id": .string(noteId)])
        #expect(after.objectValue?["tasks"]?.arrayValue?[0].objectValue?["has_image"]?.boolValue == false)
    }

    @Test("focus_note and focus:true bring the note to the foreground; a plain write only surfaces it")
    @MainActor func focusing() async throws {
        let h = try Harness()
        // create_note without focus → surfaced (open), not focused.
        let (created, _) = await call(h.tools, "create_note", ["title": "Watch me"])
        let id = try #require(created.objectValue?["id"]?.stringValue)
        #expect(h.opened.map(\.uuidString) == [id])
        #expect(h.focused.isEmpty)

        // focus_note → focus action.
        let (res, err) = await call(h.tools, "focus_note", ["note_id": .string(id)])
        #expect(!err)
        #expect(res.objectValue?["focused"]?.stringValue == id)
        #expect(h.focused.map(\.uuidString) == [id])

        // update_note focus:true → focus, not a plain open.
        h.opened.removeAll(); h.focused.removeAll()
        let (_, err2) = await call(h.tools, "update_note", ["note_id": .string(id), "focus": true])
        #expect(!err2)
        #expect(h.focused.map(\.uuidString) == [id])
        #expect(h.opened.isEmpty)
    }
}
