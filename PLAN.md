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

## Open follow-ups (post-MVP, not built now)

Daily-vs-planned rollover (the signature feature — a Today note that carries unfinished items to
tomorrow), recurring tasks, due dates + Reminders/Calendar, tags/priority, global quick-add
hotkey, **iCloud sync** (its own project with SQLite — either iCloud-Drive the DB file or build
CloudKit record sync; the UUID + `updatedAt` schema keeps this feasible), App Store
notarization.
