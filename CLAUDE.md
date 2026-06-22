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

- **No test target exists.** "Verification" is a clean `swift build` plus running the app.
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
- **CI/Release:** `.github/workflows/` — `ci.yml` (build + test + lint), `changelog.yml`
  (git-cliff updates `CHANGELOG.md` on main), `release.yml` (push a `v*` tag → builds `Tic.app`,
  git-cliff release notes, publishes a GitHub Release).
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
  `restoreAll` (launch), `openNote`, close, debounced frame persistence, roll-up resize, and
  applying float-on-top / show-on-all-Spaces.
- **`NoteController`** (`@MainActor @Observable`) — one per open note. Holds the `Note`, streams
  its tasks live via GRDB `ValueObservation`, and turns user actions into DB writes. It stays
  **AppKit-free**: window side effects go through closures the manager sets on it
  (`onApplyBehavior`, `onClose`, `onSetCollapsed`).
- **`AppDatabase`** (`Sendable`) — GRDB `DatabaseQueue` + `DatabaseMigrator`, async CRUD, and
  `ValueObservation` streams.
- **App shell** — `TicApp` (`@main`) provides a `MenuBarExtra`; `AppDelegate`
  (`NSApplicationDelegateAdaptor`) builds the shared `AppDatabase` + `NoteWindowManager` and calls
  `restoreAll()` on launch. The app is a **hybrid**: Dock icon **and** menu bar item.

### Conventions that matter (and why)

- **Targeted column writes prevent clobbering.** Window frame, title, appearance, and flags each
  have their own `UPDATE`-one-column method on `AppDatabase` (`updateNoteFrame`, `updateNoteTitle`,
  …), and `reorderTasks` writes only `sortIndex`. This is load-bearing: e.g. dragging a window
  (frequent frame saves) must not overwrite a title edit, and a live reorder must not clobber a
  task's just-edited text. Use a whole-record `update()` only where the controller owns the full
  current value (task toggle / text commit).
- **Glass is `NSVisualEffectView(.behindWindow)`, not `.glassEffect`.** `NoteBackground` renders
  the `.glass` material with a behind-window visual-effect view so it shows the *desktop* through
  it (and adopts the macOS 26 Liquid Glass look automatically). The SwiftUI `.glassEffect` API is
  for in-app controls and won't sample the desktop behind a window.
- **The window drags only by its header.** `isMovableByWindowBackground` is off; `WindowMoveArea`
  (an `NSViewRepresentable` calling `window.performDrag`) is placed behind the header / collapsed
  bar. This is what lets task rows be dragged to **reorder** without moving the window.
- **Reorder uses a direct `DragGesture`, not system `.onDrag`.** System drag has a sluggish
  pickup; the gesture is immediate. Rows publish their midpoints via a `PreferenceKey`, the drop
  indicator shows the landing spot, and the move commits once on release. This is safe on macOS
  because scrolling is the wheel/trackpad, so click-drag doesn't fight the `ScrollView`.
- **Roll-up keeps the top edge fixed.** `NoteWindowManager.setCollapsed` resizes the panel to
  `NoteLayout.collapsedHeight`, remembers the real height in `expandedHeights`, and
  `scheduleFrameSave` persists the *expanded* height/origin while collapsed so nothing is lost.
- **Theming via roles, not raw colors.** `NoteColor.color(_:on:)` resolves a role
  (title/task/secondary/completed/checkbox) for a `Surface` (`.solid` uses per-theme tuned inks;
  `.glass` uses adaptive `.primary`/`.secondary`). Views read a resolved `NoteTheme`, never branch
  on material themselves.
- **Models are sync-friendly.** `Note`/`TaskItem` use `UUID` PKs + `updatedAt`; relationships and
  defaults are chosen so CloudKit/iCloud sync stays feasible later (currently local-only).

### Swift 6 strict concurrency

`swift-tools-version: 6.0` enables Swift 6 language mode. `AppDatabase` is `Sendable`; controller
and manager are `@MainActor`. Recurring gotchas when editing: don't capture a mutable `var` in a
`@Sendable`/`Task` closure (snapshot to a `let` first); `PreferenceKey.defaultValue` must be a
`let`; qualify `CGFloat.greatestFiniteMagnitude` to avoid `Double` ambiguity in `NSSize`.

> Note: SourceKit sometimes reports `Cannot find 'X' in scope` for newly added files in the same
> module — trust `swift build`, which resolves them.
