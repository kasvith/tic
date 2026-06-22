<div align="center">
  <img src="Assets/AppIcon/Tic-256.png" width="128" alt="Tic icon">
  <h1>Tic</h1>
  <p><strong>Floating, Stickies-style task lists for macOS.</strong></p>

[![CI](https://github.com/kasvith/tic/actions/workflows/ci.yml/badge.svg)](https://github.com/kasvith/tic/actions/workflows/ci.yml)
[![Release](https://github.com/kasvith/tic/actions/workflows/release.yml/badge.svg)](https://github.com/kasvith/tic/releases)

</div>

Tic keeps your lists **on the desktop** as floating sticky notes instead of buried behind a menu
bar click — glance at them, check things off, drag them around. Each note is its own checklist.

## Features

- **Floating sticky notes** — borderless, draggable, resizable panels; optional float-on-top and
  show-on-all-Spaces per note. Positions and state are remembered across launches.
- **Multiple lists** — create from the menu bar, **⌘N**, the in-note **+**, or the Dock menu.
  New lists are auto-named *List 1, List 2, …*
- **Markdown tasks** — inline `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, links. Tap to
  edit, drag to reorder with a drop indicator.
- **Solid or Liquid-Glass** notes — per-note color themes, or a translucent material that shows
  the desktop through it.
- **Roll-up** — double-click a note's title bar to collapse it to just the header.
- **Raycast-style search palette** — a floating, centered command palette to search/open/delete
  any list, with keyboard navigation.
- **Launch at Login**, a custom menu-bar icon, and a native Dock identity.

## Requirements

macOS **14 (Sonoma)** or later.

## Install

1. Download `Tic-vX.Y.Z.zip` from the [latest release](https://github.com/kasvith/tic/releases),
   unzip it, and move **`Tic.app`** to `/Applications`.
2. Tic isn't code-signed/notarized (it's ad-hoc signed), so Gatekeeper will block it on first
   launch. Clear the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Tic.app
   ```

   Then open it normally. (Alternatively: right-click `Tic.app` → **Open** → **Open**.)
3. To have Tic open automatically, enable **Launch at Login** from its menu-bar menu.

## Build from source

Tic is a Swift Package — no `.xcodeproj` needed.

```sh
swift run                 # build + launch (dev)
swift build -c release    # release build
swift test                # run the test suite (Swift Testing)
./scripts/package.sh      # assemble dist/Tic.app (add --open to launch it)
open Package.swift        # edit in Xcode
```

## Usage

- The menu-bar icon lists your **recent lists** (with a **More Lists** submenu for the rest) and
  opens **Search Lists…**, **New List** (⌘N), and **Launch at Login**.
- Hover a note to reveal its controls: color, solid/glass, float-on-top, roll-up, **+** new list,
  and close. Click the title to rename; the bottom field adds tasks (Return keeps focus).

## Architecture

SwiftUI views hosted inside AppKit `NSPanel`s (the only way to get true desktop-sticky behavior),
backed by **SQLite via GRDB**. An `AppModel` coordinator bridges the menu bar to the window layer.
See [`CLAUDE.md`](CLAUDE.md) for the full breakdown.

**Stack:** Swift 6 · SwiftUI + AppKit · GRDB (SQLite) · `SMAppService` (login item).

## Development & releases

- **CI** (`.github/workflows/ci.yml`) builds, tests, and lints on every push/PR.
- **Changelog** is generated from [Conventional Commits](https://www.conventionalcommits.org)
  with [git-cliff](https://git-cliff.org) (`cliff.toml`) and kept in `CHANGELOG.md`.
- **Releases are tag-based:** push a `v*` tag and the release workflow builds `Tic.app`, generates
  release notes, and publishes a GitHub Release with the zipped app.

  ```sh
  git tag v0.1.0 && git push origin v0.1.0
  ```

Icon source art lives in [`Assets/`](Assets) (AppIcon / Flat / MenuBar).

## License

© 2026 Kasun Vithanage. License TBD.
