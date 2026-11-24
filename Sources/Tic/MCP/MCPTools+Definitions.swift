import CoreGraphics
import Foundation
import MCP

// The MCP tool schema (name, description, JSON-Schema input, annotations). Kept in its own
// extension so the handler struct stays focused on behaviour.
extension MCPTools {
    // MARK: - Tool definitions


    func definitions() -> [Tool] {
        let readOnly = Tool.Annotations(readOnlyHint: true)
        let destructive = Tool.Annotations(destructiveHint: true)

        return [
            Tool(name: "list_notes",
                 description: "List every Tic note (sticky) with its id, title, colour, and whether it's on screen. Call get_note for a note's tasks.",
                 inputSchema: object([:]), annotations: readOnly),

            Tool(name: "get_note",
                 description: "Get one note in full: its properties and its tasks (each with id, text, indent level 0-2, and done state).",
                 inputSchema: object(["note_id": prop("string", "The note's id")], required: ["note_id"]),
                 annotations: readOnly),

            Tool(name: "create_note",
                 description: "Create a new sticky note and open it on the desktop. Optionally seed it with tasks. Tasks build an outline: give each a level (0 top, 1-2 nested) to make sub-items.",
                 inputSchema: object([
                    "title": prop("string", "Note title (optional; auto-named if omitted)"),
                    "color": enumProp(NoteColor.allCases.map(\.rawValue), "Note colour"),
                    "material": enumProp(["solid", "glass"], "Background style"),
                    "tasks": taskArraySchema,
                    "float_on_top": prop("boolean", "Keep the note above other windows"),
                    "show_on_all_spaces": prop("boolean", "With float_on_top, also show the note on every desktop and over full-screen apps"),
                    "collapsed": prop("boolean", "Start rolled up to just the title bar"),
                    "focus": prop("boolean", "Bring Tic to the front and focus the new note (default just surfaces it without stealing focus)"),
                 ])),

            Tool(name: "update_note",
                 description: "Change a note's title, colour, material, window flags, or completed-task display, and bring it forward (open) or hide it. Only fields you pass change.",
                 inputSchema: object([
                    "note_id": prop("string", "The note's id"),
                    "title": prop("string", "New title"),
                    "color": enumProp(NoteColor.allCases.map(\.rawValue), "New colour"),
                    "material": enumProp(["solid", "glass"], "New background style"),
                    "float_on_top": prop("boolean", "Keep above other windows"),
                    "show_on_all_spaces": prop("boolean", "With float_on_top, also show on every desktop and over full-screen apps"),
                    "collapsed": prop("boolean", "Roll up to the title bar"),
                    "hide_completed": prop("boolean", "Hide checked-off tasks"),
                    "move_completed_to_bottom": prop("boolean", "Sink checked tasks to the bottom"),
                    "open": prop("boolean", "true surfaces the note (above other apps), false hides it"),
                    "focus": prop("boolean", "Bring Tic to the front and focus the note (stronger than open)"),
                 ], required: ["note_id"])),

            Tool(name: "move_note",
                 description: "Move or resize a note's window. Coordinates are global desktop points (origin bottom-left), matching how Stickies stores them.",
                 inputSchema: object([
                    "note_id": prop("string", "The note's id"),
                    "x": prop("number", "Left edge"), "y": prop("number", "Bottom edge"),
                    "width": prop("number", "Width"), "height": prop("number", "Height"),
                 ], required: ["note_id"])),

            Tool(name: "focus_note",
                 description: "Bring a note to the front and focus it (activates Tic, makes it the key window). Use to draw attention; plain writes surface a note without stealing focus.",
                 inputSchema: object(["note_id": prop("string", "The note's id")], required: ["note_id"])),

            Tool(name: "delete_note",
                 description: "Permanently delete a note and all its tasks. Cannot be undone.",
                 inputSchema: object(["note_id": prop("string", "The note's id")], required: ["note_id"]),
                 annotations: destructive),

            Tool(name: "add_tasks",
                 description: "Append tasks to a note. Each task is a string, or an object {text, level} where level 0-2 sets nesting to build sub-items. Levels are clamped to a valid outline.",
                 inputSchema: object([
                    "note_id": prop("string", "The note's id"),
                    "tasks": taskArraySchema,
                 ], required: ["note_id", "tasks"])),

            Tool(name: "update_task",
                 description: "Edit a task's text and/or tick it done. Ticking a parent ticks its subtree; finishing the last child auto-ticks the parent.",
                 inputSchema: object([
                    "task_id": prop("string", "The task's id"),
                    "text": prop("string", "New text (must not be blank)"),
                    "done": prop("boolean", "Mark done or not done"),
                 ], required: ["task_id"])),

            Tool(name: "move_task",
                 description: "Reorder a task (and its subtree) and/or re-nest it. to_index is where it lands among the note's tasks; level 0-2 sets its new depth. Tick states are preserved.",
                 inputSchema: object([
                    "task_id": prop("string", "The task's id"),
                    "to_index": prop("integer", "Target position among the note's tasks (0-based)"),
                    "level": prop("integer", "New indent level 0-2"),
                 ], required: ["task_id"])),

            Tool(name: "delete_tasks",
                 description: "Delete one or more tasks by id. Their sub-tasks are kept and re-levelled. Cannot be undone.",
                 inputSchema: object(["task_ids": .object(["type": "array", "items": prop("string", "A task id"), "description": "Task ids to delete"])], required: ["task_ids"]),
                 annotations: destructive),

            Tool(name: "clear_completed",
                 description: "Remove every checked-off task in a note. Cannot be undone.",
                 inputSchema: object(["note_id": prop("string", "The note's id")], required: ["note_id"]),
                 annotations: destructive),

            Tool(name: "set_task_image",
                 description: "Attach an image to a task (replacing any it has). Provide the image as base64 PNG or JPEG (a data: URL is also accepted). Max 10 MB.",
                 inputSchema: object([
                    "task_id": prop("string", "The task's id"),
                    "data": prop("string", "Base64-encoded PNG or JPEG"),
                 ], required: ["task_id", "data"])),

            Tool(name: "crop_task_image",
                 description: "Crop a task's image. The rect is fractions 0-1 of the image with a top-left origin; it's clamped to stay in bounds. The original is kept, so cropping is reversible.",
                 inputSchema: object([
                    "task_id": prop("string", "The task's id"),
                    "x": prop("number", "Left, 0-1"), "y": prop("number", "Top, 0-1"),
                    "width": prop("number", "Width, 0-1"), "height": prop("number", "Height, 0-1"),
                 ], required: ["task_id", "x", "y", "width", "height"])),

            Tool(name: "remove_task_image",
                 description: "Remove a task's image. If the task has no text, the task itself is removed too (an image-only task).",
                 inputSchema: object(["task_id": prop("string", "The task's id")], required: ["task_id"]),
                 annotations: destructive),
        ]
    }

    private func object(_ props: [String: Value], required: [String] = []) -> Value {
        var o: [String: Value] = ["type": "object"]
        if !props.isEmpty { o["properties"] = .object(props) }
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    private func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private func enumProp(_ cases: [String], _ description: String) -> Value {
        .object(["type": "string", "enum": .array(cases.map { .string($0) }), "description": .string(description)])
    }

    private var taskArraySchema: Value {
        .object([
            "type": "array",
            "description": "Tasks — each a string, or {text, level} where level is 0 (top), 1, or 2.",
            "items": .object(["type": .array(["string", "object"])]),
        ])
    }
}
