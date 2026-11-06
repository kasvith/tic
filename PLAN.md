# Tic — A Stickies-style floating task list for macOS

## Context

Tic is a "state of the art" task-list app for macOS, written in **Swift**. The distinguishing
idea: unlike most task apps that hide in the menu bar, **Tic lives on the desktop as floating
sticky notes** (Stickies-app style). Each note is a checklist you drop your daily or planned
tasks into and glance at without opening anything.

Dev environment is bleeding-edge — **macOS 26.5, Xcode 26, Swift 6.2** — but the app must run
on **older Macs too**, so we deploy back to **macOS 14 Sonoma** and use Liquid Glass only as a
progressive enhancement where available. Stack: **SwiftUI + SQLite (GRDB)**.

Decisions confirmed:
- **Scope:** Lean MVP first (core sticky checklist), layer features later.
- **App style:** Hybrid — dock icon **and** a menu bar item.
- **Data:** Local **SQLite via GRDB.swift**, schema kept sync-friendly for future iCloud sync.
- **Minimum OS:** macOS 14 Sonoma (keeps GRDB + MenuBarExtra; covers Macs ~2017+).
- **Look:** Solid colored "paper" notes are the universal baseline; **Liquid Glass** is an
  opt-in per-note style shown only on macOS 26+ (`if #available(macOS 26)`), gracefully
  falling back to solid on older systems. Not required.

Out of scope for v1 (deliberately deferred): daily/planned rollover, recurring tasks, due
dates/Reminders integration, tags/priority, global hotkey, iCloud sync. Models and window
layer are designed so these slot in cleanly.

## Architecture overview

The core trick of a Stickies-style app: regular SwiftUI windows can't be borderless, drag-
anywhere, float-on-top, and show-on-all-Spaces. So:

- **Views:** SwiftUI (task rows, editing, header, quick-add).
- **Windows:** AppKit `NSPanel`, one per note, each hosting a SwiftUI `NoteView` via
  `NSHostingView`. A manager class owns the `Note.id → NSPanel` map.
- **Persistence:** **SQLite via GRDB.swift** (SPM dependency). A single shared `AppDatabase`
  (wrapping a `DatabaseQueue`) is injected into the menu bar scene and every panel's hosted
  view. `.sqlite` file lives in Application Support; `ValueObservation` pushes live updates to
  SwiftUI.
- **App shell:** SwiftUI `App` providing `MenuBarExtra` + `Settings`, plus an
  `NSApplicationDelegateAdaptor` (`AppDelegate`) that restores/creates/saves panels.
- **Deployment target:** macOS 14 Sonoma. Liquid Glass (`.glassEffect()`) is used only behind
  `if #available(macOS 26, *)`, with a solid-color fallback below.

## Data model (SQLite / GRDB, sync-friendly)

Two tables defined through a GRDB `DatabaseMigrator` (versioned migrations, so the schema can
evolve safely). Records are plain Swift structs conforming to `Codable`, `FetchableRecord`,
`MutablePersistableRecord`. Sync-friendly by design: stable `UUID` primary keys + `updatedAt`
timestamps (room for last-write-wins later), foreign key with `ON DELETE CASCADE`.

- **`Note`** (`Models/Note.swift`) → table `note`: `id: UUID` (PK), `title: String`,
  `createdAt`, `updatedAt`, `color: String` (→ `NoteColor`), `material: String`
  (→ `NoteMaterial` glass/solid), window frame `frameX/Y/W/H: Double`, `floatOnTop: Bool`,
  `showOnAllSpaces: Bool`, `isCollapsed: Bool`, `sortIndex: Int`.
- **`TaskItem`** (`Models/TaskItem.swift`) → table `task`: `id: UUID` (PK),
  `noteId: UUID` (FK → `note.id`, cascade delete), `text: String`, `isDone: Bool`,
  `sortIndex: Int`, `createdAt`, `completedAt: Date?`.
- **`AppDatabase`** (`Database/AppDatabase.swift`) — opens the `DatabaseQueue`, runs migrations,
  and exposes CRUD + `ValueObservation` queries (e.g. observe all notes; observe tasks for a
  note id) that SwiftUI subscribes to.
- **`NoteColor`** (`Models/NoteColor.swift`): enum of themes (yellow, pink, blue, green,
  graphite…) → background + accent `Color`.
- **`NoteMaterial`** (`Models/NoteMaterial.swift`): `.solid` (baseline) / `.glass`
  (rendered only on macOS 26+, falls back to `.solid` below).

## Window layer (AppKit)

- **`Windows/NotePanel.swift`** — `NSPanel` subclass: `styleMask` `[.borderless, .resizable,
  .nonactivatingPanel]`, `isMovableByWindowBackground = true` (drag from anywhere),
  `isFloatingPanel`, rounded corners + shadow. `level` = `.floating` when `floatOnTop` else
  `.normal`; `collectionBehavior` includes `.canJoinAllSpaces` when `showOnAllSpaces`, plus
  `.fullScreenAuxiliary`.
- **`Windows/NoteWindowManager.swift`** — owns `[UUID: NotePanel]`. Responsibilities:
  `openNote`, `closeNote`, `restoreAll` (on launch, one panel per saved `Note`), and persisting
  frame back to the `Note` on `NSWindow.didMove`/`didResize` notifications. Holds a reference to
  the shared `AppDatabase`.

## App shell & menu bar

- **`TicApp.swift`** — `@main`. Builds the shared `AppDatabase`; injects it everywhere.
  `MenuBarExtra` (menu bar item) with: **New Note** (⌘N), **Show/Hide All**, today's open-task
  count, Settings, Quit. A `Settings` scene for preferences. `NSApplicationDelegateAdaptor`
  wires in the delegate. `LSUIElement` stays NO so the dock icon remains (hybrid).
- **`AppDelegate.swift`** — on `applicationDidFinishLaunching`, calls
  `NoteWindowManager.restoreAll()`; provides dock-menu New Note; reopens a note panel when none
  exist on dock-icon click.

## SwiftUI views

- **`Views/NoteView.swift`** — root per-note view: header + scrollable task list + quick-add.
  Background comes from `GlassBackground` (see below). Rounded corners matching the panel.
- **`Views/NoteHeaderView.swift`** — editable title, color picker, glass/solid toggle,
  float-on-top toggle, collapse button, add-note/close buttons.
- **`Views/TaskRowView.swift`** — SF Symbol checkbox (`circle` → `checkmark.circle.fill`),
  inline-editable text, strikethrough + dimmed when done, delete on hover.
- **`Views/QuickAddField.swift`** — text field; Return appends a `TaskItem` and keeps focus.
- Reordering via `List` `.onMove` (simplest) updating `sortIndex`.
- **`Views/GlassBackground.swift`** — view modifier encapsulating the background: solid
  `NoteColor` fill everywhere by default; when the note's material is `.glass` **and**
  `#available(macOS 26, *)`, apply `.glassEffect(...)`, otherwise fall back to solid. Reused by
  note body and header.

## Proposed file structure

Built as a **Swift Package** (executable target) — `swift build` / `swift run` from the CLI,
and `Package.swift` opens directly in Xcode for GUI editing. No `.xcodeproj` to maintain.

```
Package.swift            (executable target Tic, GRDB dependency, platforms macOS 14)
PLAN.md
Sources/Tic/
  TicApp.swift
  AppDelegate.swift
  Database/      AppDatabase.swift  (GRDB queue + migrations + queries)
  Models/        Note.swift  TaskItem.swift  NoteColor.swift  NoteMaterial.swift
  Windows/       NotePanel.swift  NoteWindowManager.swift
  Views/         NoteView.swift  NoteHeaderView.swift  TaskRowView.swift
                 QuickAddField.swift  GlassBackground.swift
  MenuBar/       MenuBarContent.swift
```

Note: for the MVP, `NoteColor` themes are defined in Swift (no asset catalog), so the
executable needs no resource bundle. App icon, entitlements, and a proper `.app` bundle are
deferred to the distribution step.

## Build order (implementation phases)

1. **Scaffold** the Swift package: `Package.swift` (executable target `Tic`, platforms
   `.macOS(.v14)`, dependency **GRDB 7.x**). Identifier `com.kasvith.tic` is set on the app's
   activation/bundle later when packaged; for dev we run the executable directly.
2. **Database + models**: `AppDatabase` (queue + migrations) and the `Note`/`TaskItem` records;
   seed a sample note so there's something to render.
3. **Single floating panel**: `NotePanel` + `NoteWindowManager` hosting a placeholder
   `NoteView`; verify it floats, drags from anywhere, resizes.
4. **Task list UI**: add / check / edit / delete / reorder, persisting through `AppDatabase`,
   with the list driven by `ValueObservation`.
5. **Per-note styling**: color themes + glass/solid background; float-on-top &
   show-on-all-Spaces toggles wired to panel behavior.
6. **Persistence of window state**: save frame/flags; `restoreAll()` on launch.
7. **Menu bar + dock**: `MenuBarExtra` actions, ⌘N, Show/Hide All, today count.
8. **(Optional in v1)** Launch-at-login via `SMAppService`.

## Verification

- Build with **`swift build`** (resolves the GRDB SPM dependency; CI-style check) and launch
  with **`swift run`**. The executable calls `NSApp.setActivationPolicy(.regular)` to get a
  dock icon + foreground focus without a bundle. `Package.swift` also opens in Xcode.
- **Compatibility check:** on macOS 26 a glass note renders frosted; on macOS 14–15 the same
  note falls back to solid color with no crash (test the `#available` path).
- **Inspect the data:** open the `.sqlite` file in Application Support with any SQLite browser
  and confirm `note`/`task` rows match the UI.
- Manual end-to-end pass:
  1. Launch → menu bar item + dock icon appear; saved notes restore as floating panels.
  2. **New Note** (menu bar / ⌘N) → a sticky panel appears.
  3. Add several tasks, check some (strikethrough), edit text, reorder, delete one.
  4. Move + resize the panel; toggle glass↔solid and a color; toggle float-on-top (note stays
     above other apps) and show-on-all-Spaces (switch desktops — note follows).
  5. **Quit and relaunch** → notes, tasks, positions, colors, and flags all restored.
  6. Menu bar shows correct count of today's open tasks.
- Optionally drive the built app with the `run` / `verify` skills once it compiles.

## MCP: AI agents drive Tic (planned, next)

Agents (Claude Desktop/Code, Cursor, VS Code, Codex, Gemini, Windsurf, Zed, …) get **full
parity with a human** over notes and tasks through an MCP server, and the UI reflects every
agent write instantly. Off by default; a menu-bar item **AI Agents (MCP)…** opens the setup
window that holds the toggle and per-client install instructions.

### The one decision that keeps this small: the server runs *inside* the running Tic

- **Live updates cost nothing.** Every tool writes through the existing `AppDatabase`, and the
  existing `ValueObservation` streams (`observeTasks`, `observeTaskImageCrops`, `observeNotes`)
  already push those writes into the views. A standalone `tic-mcp` binary writing the SQLite file
  would need a hand-built cross-process notification channel: GRDB does not observe other
  processes' writes.
- **One gap to close:** an open note's `NoteController` streams its tasks but holds its `note`
  row as a one-time snapshot, and `NoteView` seeds the title field once. Add
  `AppDatabase.observeNote(id:)` (per-row twin of `observeNotes()`), subscribe in
  `NoteController.start()`, diff each emission against the current `note` and fire the existing
  closures when their fields changed (`onApplyBehavior` for float/all-Spaces, `onSetCollapsed`
  for roll-up). Diffing against the optimistic in-memory value makes the controller's own writes
  echo back as no-ops. `NoteView` syncs `titleText` from `controller.note.title` while the field
  isn't focused. Colour/material/list options already render from `controller.note`.
- **Window actions go direct, not via reconcile.** Open/close/bring-to-front/move hop to the
  main actor and call `NoteWindowManager` (`openNote`, new `closeNote(id)`, `setFrame(id:)`).
  Reconciling panels from the notes observer was considered and dropped: `openNote` writes
  `isOpen` asynchronously, so an emission in that gap looks like a closed note with a panel.
  A programmatic `setFrame` fires `windowDidMove`/`windowDidResize`, so the existing debounced
  save persists an agent move with no new code.

### Transport: stdio to the client, a Unix socket inside

```
Claude / Cursor / … ──stdio──▶ Tic --mcp (proxy) ──unix socket──▶ Tic.app: MCPServer ─▶ AppDatabase
                                                    one connection per client   one serialised writer
```

- **Clients see stdio only**, the one transport every MCP client supports. Every client config
  is identical: `command: <Tic.app>/Contents/MacOS/Tic`, `args: ["--mcp"]`.
- **The proxy is the same binary.** `@main` on `TicApp` becomes a `main.swift`: `--mcp` runs
  `MCPProxy` (pipe stdin → socket, socket → stdout, exit on EOF) instead of the GUI. No second
  target, no packaging change. If the socket is missing, launch Tic via
  `NSWorkspace.openApplication(at:)` without activating and retry for a few seconds; if it's
  still missing (MCP off) print a one-line hint to stderr and exit 1, which clients surface in
  their logs. Under `swift run` the path is `.build/debug/Tic`, so dev testing works the same.
- **The inner hop is a Unix domain socket** at `~/Library/Application Support/Tic/mcp.sock`
  (Network.framework: `NWListener` with `requiredLocalEndpoint = .unix(path:)`, available since
  macOS 10.15). Chosen over localhost TCP because it needs no port, triggers no macOS firewall
  prompt, and is a 0600 file in the user's Library, the same exposure as the SQLite file, not a
  port open to every local process and browser page. Unlink a stale socket before binding.
  (`sun_path` max is 104 bytes; the App Support path is ~50.)
- **Many agents at once** just work: the listener accepts one connection per client, each is its
  own MCP session (own `initialize`, own request ids, handled in order per connection), and all
  writes serialise through the `DatabaseQueue` (`MAX(sortIndex)+1` is computed inside the write).
  Two agents editing one task is last-write-wins, the same rule as user-vs-agent today.
- Skipped: Streamable HTTP (needs an HTTP+SSE server or a dependency, Origin/auth per spec, the
  firewall prompt, and Claude Desktop's config file still only spawns stdio). Add if a client
  that can't spawn a process shows up.

### Protocol: hand-rolled, five methods

Newline-delimited JSON-RPC 2.0, exactly MCP's stdio framing, so the proxy pipes bytes
untouched. `MCPServer` handles `initialize` (echo the client's `protocolVersion` when known,
else ours; `capabilities.tools`; a short `instructions` string describing notes, the
three-level outline and the completion cascade), `notifications/initialized` (ignored),
`ping`, `tools/list`, `tools/call`; anything else → `-32601`. The dispatcher is a pure
`handle(line) async -> String?` over an `AppDatabase`, so tests drive it with strings on an
in-memory DB. The official swift-sdk is skipped (three transitive dependencies for five
methods); switch if resources/prompts/sampling are ever wanted.

### Tools: everything a human can do to notes and tasks

| Tool | Covers | Path |
|---|---|---|
| `list_notes`, `get_note` | Lists palette; reading a note (tasks with id/text/level/done/has_image) | reads |
| `create_note` | ⌘N, with title/color/material/tasks/frame; cascaded placement like `newNote` | insert + `openNote` |
| `update_note` | title, color, material, float, all-Spaces, collapsed, hide-completed, sort-to-bottom, `open` (X / bring to front) | targeted column writes → note observer; `open` → manager |
| `move_note` | drag/resize; global coordinates spanning displays, as stored | manager `setFrame` |
| `delete_note` | palette delete | `destructiveHint` |
| `add_tasks` | quick-add, add subtask, add sibling (`after_task_id` + `level`) | `insertTask` / `insertTask(reordering:)` |
| `update_task` | edit text; tick/untick with the bidirectional cascade | `update` / `applyingToggle` + `updateTaskCompletion` |
| `move_task` | drag reorder, indent, outdent | `movingSubtree` + `normalizedLevels` + `applyStructuralUpdate` |
| `delete_tasks`, `clear_completed` | delete, clear completed | `destructiveHint` |
| `set_task_image`, `crop_task_image`, `remove_task_image` | paste, crop (0…1 top-left rect), remove; base64 PNG/JPEG | `TaskImage` helpers + existing writes |

- **Trust boundary validation:** unknown ids → tool error (`isError: true`), text trimmed and
  capped, blank text rejected (deletion is explicit), level 0…`TaskItem.maxIndentLevel`, batch
  and image size capped, colors/materials by raw value.
- **Conventions carry over:** completion changes only via the toggle cascade; structural edits
  never touch `isDone`; level diffs by id (`indentLevelChanges`); targeted column writes only.
  `NoteController.completionChanges` moves to `TaskOutline` so both callers share it.
- **Annotations** (`readOnlyHint`, `destructiveHint`, `idempotentHint`) ride along so clients ask
  the user before an agent deletes anything.
- **Defaults:** a write to a closed note reopens it so the user sees the work.
- **Excluded on purpose:** launch at login, the MCP toggle itself, quit, update check, the
  transient image viewer window. App controls, not note content.

### Setup window (signed-off mockup)

```
┌──────────────────────────────────────────────────────────────┐
│  AI Agents (MCP)                                          ✕  │
│  Let Claude, Cursor and friends draft and tick your lists.    │
│                                                               │
│  (●   ) Enable MCP server           ● Running · 1 connected   │
│                                                               │
│  Claude Desktop  ▸ │  Add this to claude_desktop_config.json  │
│  Claude Code       │  ┌────────────────────────────────────┐  │
│  Cursor            │  │ { "mcpServers": { "tic": {         │  │
│  VS Code           │  │     "command": "/Applications/…/Tic",│ │
│  Codex CLI         │  │     "args": ["--mcp"] } } }         │  │
│  Gemini CLI        │  └────────────────────────────────────┘  │
│  Windsurf          │  [ Copy ]  [ Open config file ]          │
│  Zed               │                                          │
│  Other (JSON)      │  CLIs show a one-line `… mcp add` command │
│                    │  instead; Cursor gets an "Add to Cursor" │
│                    │  deeplink button.                        │
│                                                               │
│  ⚠ Tic isn't in /Applications, the path changes if you move it│
└──────────────────────────────────────────────────────────────┘
```

- Built like the Lists palette: an `NSPanel` hosting SwiftUI, owned by `AppModel`
  (`openMCPSetup()`), `.regularMaterial`, ~640×420.
- `MCPClients` is one static table: name, config path, snippet shape (`mcpServers` JSON /
  `servers` JSON / TOML / CLI command), optional deeplink. Adding a client is one array entry.
  The executable path is read live from `Bundle.main.executableURL`, so it's right for dev too.
- Preference `mcpEnabled` (UserDefaults, default off); `AppModel.setMCPEnabled` starts/stops the
  listener; `bootstrap()` starts it when on. Status text is the listener's live connection count.
- No activity feed and no highlight animation on agent edits in v1 (the live update already
  shows them). Add the feed when debugging agents gets annoying.

### Files (~1,000 lines incl. tests)

```
Sources/Tic/
  main.swift                       --mcp → MCPProxy, else TicApp.main()  (@main removed)
  MCP/MCPServer.swift              NWListener, line framing, JSON-RPC dispatch, sessions
  MCP/MCPTools.swift               the tool table + handlers over AppDatabase (+ main-actor window calls)
  MCP/MCPProxy.swift               stdio ↔ socket bridge, auto-launch, off-hint
  MCP/MCPClients.swift             client instruction table
  Views/MCPSetupView.swift         the window
  AppModel.swift                   mcpEnabled, start/stop, openMCPSetup()
  TicApp.swift                     menu item
  Database/AppDatabase.swift       observeNote(id:)
  Controllers/NoteController.swift note-row observation + diff → closures
  Windows/NoteWindowManager.swift  closeNote(id:), setFrame(id:_:)
  Views/NoteView.swift             titleText sync
  Models/TaskOutline.swift         completionChanges (moved from the controller)
Tests/TicTests/
  MCPServerTests.swift             handshake, tools/list, unknown method, framing split/joined lines
  MCPToolsTests.swift              create→get round trip, level clamping, done cascade, move re-nest,
                                   update_note/move_note round trip, bad ids, image set/crop/remove
  NoteControllerTests.swift        note observer fires closures on change, quiet on echo; rename lands
```

### Build order

1. **Spike** (`main.swift`, `MCPProxy`, an echo listener). Verify: the Unix-socket listener
   accepts connections; `swift test` still works with `main.swift` instead of `@main`; a client
   spawning the GUI binary with `--mcp` shows no Dock icon; `claude mcp add tic --
   $PWD/.build/debug/Tic --mcp` then `claude mcp list` reports it connected.
2. **Protocol + tools + tests**: `MCPServer`, `MCPTools`, `observeNote`, controller observer,
   `closeNote`/`setFrame`, `titleText` sync.
3. **Toggle + menu item**, then the **setup window** per the mockup.
4. **Docs**: CLAUDE.md conventions (in-process server, stdio-via-`--mcp`, note observer, direct
   window calls), README and site "Works with AI agents" mention.

### Verification

- `swift build`, `swift test` (the MCP suites drive the dispatcher with JSON-RPC lines over an
  in-memory database).
- Manual, user-driven: enable MCP, add Tic to Claude Code with the command above, then ask it to
  draft a list. Watch: the note appears cascaded; asking it to rename, recolour, roll up, float,
  move, tick a parent (subtree ticks), add subtasks, and delete a task each show instantly in the
  open panel. Toggle MCP off → the agent's next call fails with the stderr hint. Connect a second
  client and confirm "2 connected" and that both see each other's writes via `get_note`.

## Sync between Macs (planned)

The request: one person, two Macs (work laptop + home desktop), used **one at a time**. Same lists
on both, changes carried between sessions, but **each Mac chooses which lists are open**.

### Decision: files in a synced folder, not CloudKit

CloudKit (and every other iCloud API) needs the iCloud entitlement, which an ad-hoc signed app can't
carry — it takes a paid Developer Program account, Developer ID signing, a provisioning profile and
notarisation. A synced *folder* needs none of that: Tic only reads and writes plain files, and
whatever syncs the folder does the networking. Default `iCloud Drive/Tic`; a "Choose Folder…"
picker covers a work Mac without personal iCloud (Dropbox, Google Drive, OneDrive, Syncthing).
Rejected: the SQLite file itself in iCloud Drive (WAL files sync separately → corruption), a server
of our own (accounts, hosting, breaks local-only), LAN peer-to-peer (the Macs are rarely on together).

### Shape: one file per Mac, a last-writer-wins CRDT

```
<sync folder>/devices/<deviceId>.json   ← each Mac writes only its own file
<sync folder>/images/<sha256>.png       ← immutable, named by content
```

- **Single writer per file**, so a sync service never sees a write conflict (no "conflicted copy").
- **Export** (a second or two after a DB change, via a GRDB observation on `note`/`task`): diff the
  DB against this Mac's last snapshot, stamp the changed fields, write the file atomically. Offline
  is fine — the write is local and uploads later.
- **Import** (launch, wake, ~30 s poll): read the other Macs' files, merge with the pure
  `SyncMerge`, apply in one transaction, and copy the winners into this Mac's snapshot so it doesn't
  re-claim them. SQLite stays the only source of truth; the schema is unchanged; open panels update
  through the existing `ValueObservation`s.
- The merge is a state-based CRDT (commutative, idempotent), so file read order and repeats don't
  matter. Tests assert exactly those properties plus the rules below.

| What | Rule |
|---|---|
| Task text, `isDone` (+ `completedAt`) | One register per field; newest stamp wins |
| Note title, colour, material, list options | One register per field; newest stamp wins |
| A note's task order + nesting | **One register for the whole outline** (`[(taskId, level)]`); newest wins; a task missing from the winner goes after its previous neighbour; written back via `applyStructuralUpdate` + `normalizedLevels` |
| Deletes | **Delete always wins**, even over a newer edit; a deleted note takes its tasks |
| Frame, `isOpen`, collapsed, float, all-Spaces, the note's own `sortIndex` | Never in the file — per Mac |
| Stamp | `max(now, highest stamp seen + 1)`; a same-millisecond tie goes to the larger encoded value, so every Mac picks the same winner |

Per-field registers mean a tick on one Mac and a text edit on the other both survive; the outline as
one register means two reorders never interleave into a jumble. Files carry a `schema` number — a
Mac that sees a newer one skips it and asks to update Tic.

- **Sync is per list and opt-in.** New lists stay on their Mac until switched on (⋯ › Sync, or the
  list of lists in Settings › Sync). The switch is itself a register: off on one Mac is off on all,
  every Mac keeps its copy, and only synced lists are written to the folder. Every Mac keeps recording
  all its lists locally, so switching a list back on merges the copies field by field. A list deleted
  while synced is deleted everywhere; one deleted while not synced only on that Mac (noted by a trigger
  at deletion time). The note's sync mark shows only while a sync touches it (orange while the folder
  can't be reached), and ⋯ has Sync Now.
- A list **created on the other Mac arrives closed** and shows up in the menu-bar Lists; opening it
  makes it open on that Mac from then on.
- Settings › Sync lists each other Mac with **"Latest changes <time>"** — the real risk with
  one-at-a-time use is the laptop lid closing before its upload finishes, and this lets the user see
  whether changes arrived. Tic also writes pending edits at once when the Mac goes to sleep.
- Welcome notes never sync unless switched on, so nothing is duplicated.

**Accepted limits** (rare for one person on one Mac at a time): the same task's text edited on both
Macs before a sync → one version wins; a parent ticked on one Mac while a child is added under it on
the other → ticked parent with an unticked child; deletion markers are kept forever (tiny).
Automerge/Yjs would merge text character by character, but only help with simultaneous editing,
would make SQLite a second source of truth, and add a Rust dependency — revisit only for lists
shared live with other people.

### Build order

1. Check on one Mac that an ad-hoc `.app` can write to iCloud Drive (privacy prompt? re-asked after a
   rebuild changes the signature?).
2. `SyncSnapshot` + `SyncMerge` (pure, unit-tested) and the export/import loop (`FolderSync`),
   notes + tasks only, set up in a new **Settings window** (General · Sync · AI Agents), which also
   takes over Launch at Login, update-check frequency, and the MCP setup window. *(Built.)*
3. Images as content-addressed files (`images/<sha256>.png`), and per-list opt-in. *(Built.)*

## Open follow-ups (post-MVP, not built now)

Daily-vs-planned rollover (the signature feature — a Today note that carries unfinished items to
tomorrow), recurring tasks, due dates + Reminders/Calendar, tags/priority, global quick-add
hotkey, App Store notarization. (Sync between Macs: see above.)
