# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Tic** is a macOS app of floating, Stickies-style task notes that live on the desktop. It's a
SwiftPM **executable** (no `.xcodeproj`), SwiftUI for views, AppKit for windows, and **SQLite via
GRDB** for storage. Deployment target is **macOS 14**; the dev toolchain is Swift 6.2 / Xcode 26.
`PLAN.md` is the design doc and roadmap (what's built vs. deferred).

## Commands

```bash
swift build                 # compile (resolves the GRDB SPM dependency); the source of truth
swift run                   # build + launch the GUI app (long-running; kill it when done)
open Package.swift          # opens the package in Xcode for GUI editing / previews
./scripts/package.sh        # build release + assemble dist/Tic.app (add --open to launch it)
```

- **Landing page** (tic.kasvith.me) is a self-contained Astro + pnpm project in `site/` — all Node
  tooling stays there (see `site/README.md`); never add JS files to the repo root.
- **Install/update script**: `site/public/install.sh`, served as
  `curl -fsSL https://tic.kasvith.me/install.sh | sh`. curl adds no quarantine flag (browsers do), so
  the unsigned app opens without Gatekeeper's block. It verifies `Tic.zip.sha256` and quits only the
  app process (the `pgrep -f` pattern is anchored, so `Tic --mcp` helpers and their wrappers survive).
  Test it with `TIC_DEST=<tmp dir>` and a stub `open` first on `PATH`.
- **Verification** is a clean `swift build`, `swift test` (Swift Testing — `AppDatabaseTests`,
  `TaskOutlineTests`, `NoteColorTests`, `TaskImageTests`, …), plus running the app. The outline logic lives in pure,
  testable functions (`TaskOutline`) precisely so it can be covered without a DB or the main actor.
- `swift run` produces a bare executable (no bundle): fine for dev, but it has no Dock identity
  and **can't register as a login item** (SMAppService needs a real bundle).
- **Packaging** (`scripts/package.sh` + `Packaging/Info.plist`) assembles a real `dist/Tic.app`
  with bundle id `com.kasvith.tic` and the icon from `Assets/AppIcon/Tic.icns`
  (→ `Resources/AppIcon.icns`, referenced by `CFBundleIconFile`). That's what gives the Dock
  icon/name and makes Launch-at-Login work. It's ad-hoc signed; a Developer ID + notarization is
  needed for distribution. For the login item to persist, run from a stable location (move
  `Tic.app` to /Applications).
- **Tests:** `swift test` (Swift Testing; `@testable import Tic` works on the executable target —
  no separate library). `Assets/` holds source icon art (AppIcon / Flat / MenuBar); the menu-bar
  glyph is also copied to `Sources/Tic/Resources/MenuBarIcon.png` and bundled via SwiftPM.
- **CI/Release:** `.github/workflows/` — `ci.yml` (build + test + lint) and `release.yml` (push a
  `v*` tag → builds `Tic.app`, git-cliff release notes, publishes a GitHub Release (versioned DMG +
  a stable-named `Tic.zip` and `Tic.zip.sha256`, which `releases/latest/download/…` always resolves),
  commits the
  regenerated `CHANGELOG.md` to main, then POSTs the `CF_DEPLOY_HOOK` secret so the site's
  What's new rebuilds — that commit is `[skip ci]`, which Cloudflare honours).
- To launch headlessly for a no-crash smoke check (the GUI can't be screenshotted from a
  sandbox), run `.build/debug/Tic` in the background and grep its stderr for the
  `[Tic] restored N note panel(s)` log line.

### Inspecting / resetting state

The database is a plain SQLite file you can read and edit directly:

```bash
DB="$HOME/Library/Application Support/Tic/tic.sqlite"
sqlite3 -header -column "$DB" "SELECT title,color,material,floatOnTop,isCollapsed FROM note;"
rm "$DB"                    # wipe; the welcome note is re-seeded on next launch
```

In **DEBUG** builds the migrator sets `eraseDatabaseOnSchemaChange = true`, so changing the schema
auto-wipes the DB instead of crashing.

## Architecture

The defining constraint: a desktop sticky note needs borderless/float/all-Spaces/custom-drag
behavior that pure SwiftUI windows can't provide. So **SwiftUI views are hosted inside AppKit
panels**, and a few responsibilities are deliberately split across the AppKit/SwiftUI boundary.

- **`NotePanel`** (AppKit `NSPanel`) — one window per note. Titled but with a hidden transparent
  title bar + `fullSizeContentView` (gives rounded corners, shadow, edge-resize while the SwiftUI
  content fills everything). `isMovableByWindowBackground` is **off** on purpose.
- **`NoteWindowManager`** (`@MainActor`) — owns `[UUID: NotePanel]` + `[UUID: NoteController]`, is
  each panel's `NSWindowDelegate`, and is the single chokepoint for all window mutation:
  `restoreAll` (launch: only notes with `isOpen` — the header X clears it, quitting doesn't, so
  relaunch shows what was on screen), `openNote`, close, debounced frame persistence, roll-up
  resize, and applying float-on-top / show-on-all-Spaces. Frames are global coordinates spanning
  all displays, exactly as Stickies stores them. **Only user drags/resizes persist a frame**: `place`
  puts a note at its saved frame when any connected display shows it, else parks it at the nearest
  edge of the main display, and re-runs on `didChangeScreenParametersNotification` with saves
  suppressed (`placing` + a 2s blackout) — so unplugging a monitor never overwrites the note's spot
  on it, and plugging it back returns the note exactly, with or without a relaunch in between.
- **`NoteController`** (`@MainActor @Observable`) — one per open note. Holds the `Note`, streams
  its tasks live via GRDB `ValueObservation`, and turns user actions into DB writes. It stays
  **AppKit-free**: window side effects go through closures the manager sets on it
  (`onApplyBehavior`, `onClose`, `onSetCollapsed`).
- **`AppDatabase`** (`Sendable`) — GRDB `DatabaseQueue` + `DatabaseMigrator`, async CRUD, and
  `ValueObservation` streams.
- **`TaskOutline`** (pure, no AppKit / no DB) — all the subtask/outline maths over a note's flat
  `[TaskItem]`: subtree/parent/children queries, the bidirectional completion cascade
  (`applyingToggle`), indent/outdent, drag-move (`movingSubtree`), level `normalizedLevels`, and the
  id-matched `indentLevelChanges` diff. Kept separate so it's unit-testable in isolation.
- **`PlainTextEditor`** (`NSViewRepresentable` over `NSTextView`) — the task / quick-add editor.
  AppKit, not SwiftUI `TextField`, because that control can't reliably insert newlines or intercept
  Tab on macOS (see the editing convention below). **`QuickAddBar`** is the add-a-task bar along the
  bottom of a note (owns the typed text and pending indent). **`ShortcutHint`** is the small keycap-chip label.
- **`TaskImage`** (pure CoreGraphics/ImageIO, no AppKit / no DB) + **`TaskImageView`** — pasted images:
  normalise/thumbnail/crop/preview-file helpers and the crop maths (`dragging`, `moving`), and the view
  that draws a task's image with its hover buttons, context menu, and crop mode. **`ImageViewer`** is the
  image window a double-click opens (AppKit `ZoomScrollView` zoom + Open in Preview), dressed like its
  note (paper/glass background, note-style header, hints) — one reusable `ImageWindow` owned by
  `NoteWindowManager`; far quicker than launching Preview.
- **MCP server (`MCP/`)** — lets AI agents drive Tic. `MCPService` runs an `NWListener` on a Unix
  socket beside the DB (`~/Library/Application Support/Tic/mcp.sock`, 0600) — one official-SDK
  `Server` session per connection (per agent). `MCPTools` is the tool surface (`create_note`,
  `add_tasks`, `update_task`, `move_task`, …): pure `AppDatabase` writes plus three window pokes
  (`WindowActions`), reusing `TaskOutline` for every structural rule so tools and UI can't diverge.
  Clients speak **stdio** to `Tic --mcp` (`MCPProxy`), which pipes to the socket — one config works
  for every client, and the server lives in the app next to the observers. Off by default
  (`AppModel.mcpEnabled`). **Live updates are free:** tools write the DB, the existing
  `ValueObservation` streams push into open panels; the one addition is `observeNote(id:)` so the
  controller streams its own note row too (an agent's title/colour/flag write shows live).
- **App shell** — `TicApp` provides a `MenuBarExtra`; `main.swift` (not `@main`) routes `--mcp` to
  the proxy, else `TicApp.main()`; `AppDelegate`
  (`NSApplicationDelegateAdaptor`) builds the shared `AppDatabase` + `NoteWindowManager` and calls
  `restoreAll()` on launch. The app is a **hybrid**: Dock icon **and** menu bar item.

### Conventions that matter (and why)

- **Targeted column writes prevent clobbering.** Window frame, title, appearance, and flags each
  have their own `UPDATE`-one-column method on `AppDatabase` (`updateNoteFrame`, `updateNoteTitle`,
  …). For tasks, `applyStructuralUpdate` (optional delete + `sortIndex` reorder + `indentLevel`, all
  in one transaction) and `updateTaskCompletion` (`isDone`/`completedAt`) each touch only their own
  columns. This is load-bearing: dragging a window (frequent frame saves) must not overwrite a title
  edit, a reorder must not clobber a just-edited task's text, and a checkbox toggle must not clobber
  a concurrent text edit. A whole-record `update()` is used only for a task **text** commit (where
  the controller owns the full current value).
- **Subtasks are a flat list + an `indentLevel`, not a parent-id tree.** A task's *parent* is
  implicit — the nearest preceding row with a smaller level (max 3 levels). `TaskOutline` keeps the
  *outline invariant* (first row level 0; no row more than one level deeper than the row above) via
  `normalizedLevels` after every structural edit, so an orphaned/jumped level can never render. When
  persisting level changes, diff **by id** against the current `tasks` (`indentLevelChanges`), not by
  position — a drag reorders *and* re-nests, so a positional diff would miss the level change (this
  was a real bug). New subtasks insert mid-list via `insertTask(_:reordering:)`; everything else
  appends with `insertTask` (atomic `MAX(sortIndex)+1`, so deletes leaving gaps can't collide).
- **Completion changes only via `toggle`; structural edits preserve ticks.** `toggle` runs the
  bidirectional cascade (checking a parent checks its whole subtree; finishing the last child
  auto-completes the parent — `TaskOutline.applyingToggle`). Move / indent / outdent / delete / add
  **never** touch `isDone` — moving a checked item around leaves every tick exactly as it was.
- **The editor is AppKit (`PlainTextEditor`/`NSTextView`), not SwiftUI `TextField`.** On macOS that
  control neither reliably inserts line breaks nor lets us intercept Tab (the key-view loop eats it
  before `.onKeyPress`). `EditorTextView.keyDown` gives deterministic chords: Return commits,
  Shift/Option-Return inserts a newline, Shift-Tab nests, Ctrl-Shift-Tab outdents. It forces TextKit
  1 (`_ = view.layoutManager`) so `usedRect` can size it (TextKit 2's `layoutManager` is nil and
  multiline would clip), reports height via `sizeThatFits`, and an `editorFirstBaseline()` guide
  aligns the adjacent checkbox to the editor's first line (an NSView has no SwiftUI text baseline).
  A blank/whitespace-only task is deleted on commit, so an abandoned new row just disappears.
- **Images: one per task, own table, crop is just a rect.** `taskImage` (PK `taskId`, cascades with the
  task) holds the original PNG plus a crop normalised 0…1 with a **top-left** origin (CGImage pixel
  space — no flip). It's a separate table so `observeTasks` never loads blobs, and the crop has its own
  targeted `updateTaskImageCrop`. The controller observes only crops (`observeTaskImageCrops`, never
  `data`) and decodes a downsampled thumbnail off the main actor; rows draw that through
  `CroppedImageCache`, never the full image (a drag re-renders every row each frame). ⌘V routing: a
  focused `EditorTextView.paste` (row → attach; quick-add → `stageImage`), otherwise `NotePanel.paste`
  (also `stageImage`, which focuses the quick-add via `quickAddFocusRequest`). A staged image waits in
  the quick-add until **Return** adds it with the typed text; focus loss doesn't submit while one waits; `NSPasteboard.pastableImageData` decides image vs text (an
  image file wins; raw image data only when there's no plain text). An image keeps an empty-text task
  from the blank-task delete. Open in Preview renders a temp PNG of the cropped image
  (`TaskImage.writePreviewFile`). Crop mode's mouse and keys are AppKit (`CropTrackingView`), SwiftUI only draws it: a
  SwiftUI `DragGesture` there kept following the pointer after mouse-up, and SwiftUI focus never
  arrived, so ⏎ / ⎋ / click-away did nothing. Images size through the `AspectFit` layout:
  `.aspectRatio(.fit)` + `.frame(maxHeight:)` laid out row-wide, dragging the hover chrome to the note's edge.
  Pointing at or cropping an image pauses its row's reorder drag (`GestureMask.subviews`) — SwiftUI's row
  `DragGesture` otherwise also fires over the image's buttons and even the AppKit crop view.
- **Rendered Markdown is memoised (`MarkdownRenderCache`).** Parsing inline Markdown per line on
  every body re-eval made dragging janky (the whole list re-renders each frame); the cache re-parses
  only when a task's text/colour actually changes.
- **Glass is `NSVisualEffectView(.behindWindow)`, not `.glassEffect`.** `NoteBackground` renders
  the `.glass` material with a behind-window visual-effect view so it shows the *desktop* through
  it (and adopts the macOS 26 Liquid Glass look automatically). The SwiftUI `.glassEffect` API is
  for in-app controls and won't sample the desktop behind a window.
- **The window drags only by its header.** `isMovableByWindowBackground` is off; `WindowMoveArea`
  (an `NSViewRepresentable` calling `window.performDrag`) is placed behind the header / collapsed
  bar. This is what lets task rows be dragged to **reorder** without moving the window.
- **Reorder uses a direct `DragGesture`, not system `.onDrag`.** System drag has a sluggish
  pickup; the gesture is immediate. The dragged block (row + subtree) lifts into an overlay
  (`LiftedRow`) and its head row turns into a ghost `DropPlaceholder` at the drop slot and level;
  the receiving parent is tinted with an elbow (`DropThread`) into it. The dragged row stays
  **mounted** (invisible, one line tall) under the placeholder: it took the mouse-down, and removing
  it makes SwiftUI silently stop the drag's events (no end, no cancel — a stuck drag).
  `ReorderDragTests` hosts a real `NoteView` in a `NotePanel` and drives it with synthetic events via
  `window.sendEvent` (not `NSApp.postEvent` + a `nextEvent` pump, which stalls the main actor for
  later tests; hit-test first — a press on a text field starts a tracking loop that never returns).
  Rows publish their frames via a `PreferenceKey`; the
  slot counts rest-row midpoints *with the gap open* (so it only moves once a neighbour is fully
  crossed — no flicker). Per-frame pointer state lives in the `@Observable` `ReorderDrag`, read
  only by `LiftedRow`, so the list re-renders on slot/level changes, not every frame. Drop rules
  are pure in `TaskOutline` (`dropLevels`: never adopt the row below; `levelSteps`: ~70% of an
  indent step to re-nest). Safe on macOS because scrolling is the wheel/trackpad, so click-drag
  doesn't fight the `ScrollView`.
- **Roll-up keeps the top edge fixed.** `NoteWindowManager.setCollapsed` resizes the panel to
  `NoteLayout.collapsedHeight`, remembers the real height in `expandedHeights`, and
  `scheduleFrameSave` persists the *expanded* height/origin while collapsed so nothing is lost.
- **Theming via roles, not raw colors.** `NoteColor.color(_:on:)` resolves a role
  (title/task/secondary/completed/checkbox) for a `Surface` (`.solid` uses per-theme tuned inks;
  `.glass` uses adaptive `.primary`/`.secondary`). Views read a resolved `NoteTheme`, never branch
  on material themselves.
- **Updates are check-only (`UpdateChecker`), never auto-install.** Tic is ad-hoc signed, so a
  self-replacing updater (Sparkle) can't be trusted. Daily GET of the GitHub `releases/latest` API,
  compared numerically against `CFBundleShortVersionString` (nil under `swift run` → checker off).
  A newer tag shows a menu-bar item, a dot on the menu-bar icon until the menu is opened or the
  item clicked (`isUnseen`, remembered in the `updateSeenVersion` default; "opened" is detected via
  `NSMenu.didEndTrackingNotification` on a menu containing our item; the dot is **drawn into a
  second template `NSImage`** because the status item renders only the label's image, never a
  SwiftUI overlay), and **one** notification
  banner per version (`updateNotifiedVersion`; authorization is requested only then, so the system
  prompt appears in context). `UNUserNotificationCenter` needs a bundle id, so both the delegate
  and the banner are guarded. `package.sh` defaults `VERSION` to the latest git tag so a local build
  isn't "outdated".
  - **Seeing it locally:** `VERSION=0.1.0 ./scripts/package.sh --open` shows the menu item and the
    dot. The banner is stricter: macOS refuses notification authorization (`UNErrorDomain` code 1,
    "Notifications are not allowed for this application") for an ad-hoc bundle **outside
    /Applications**, and the refusal seemed to stick to the bundle id afterwards. So to test the
    banner, copy the build to `/Applications/Tic Dev.app`, give it a unique `CFBundleIdentifier`
    (PlistBuddy), re-sign ad-hoc, then `open` it. Re-arm with
    `defaults delete <bundle id> updateNotifiedVersion updateSeenVersion`, and delete the copy after.
- **Models are sync-friendly.** `Note`/`TaskItem` use `UUID` PKs + `updatedAt`; relationships and
  defaults are chosen so CloudKit/iCloud sync stays feasible later (currently local-only).

### Swift 6 strict concurrency

`swift-tools-version: 6.0` enables Swift 6 language mode. `AppDatabase` is `Sendable`; controller
and manager are `@MainActor`. Recurring gotchas when editing: don't capture a mutable `var` in a
`@Sendable`/`Task` closure (snapshot to a `let` first); `PreferenceKey.defaultValue` must be a
`let`; qualify `CGFloat.greatestFiniteMagnitude` to avoid `Double` ambiguity in `NSSize`.

> Note: SourceKit sometimes reports `Cannot find 'X' in scope` for newly added files in the same
> module — trust `swift build`, which resolves them.
