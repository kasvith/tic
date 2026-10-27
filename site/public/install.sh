#!/bin/sh
# Installs or updates Tic (https://tic.kasvith.me):
#
#   curl -fsSL https://tic.kasvith.me/install.sh | sh
#
# Tic isn't notarized, and a browser download gets macOS's quarantine flag, which makes Gatekeeper
# block the first launch. curl doesn't add that flag, so Tic installed this way just opens — no
# `xattr` step. Run it again to update. Set TIC_DEST to install somewhere other than /Applications.
set -eu

fail() {
    printf 'tic: %s\n' "$1" >&2
    exit 1
}

# Everything runs from main, called on the last line, so a half-downloaded script does nothing.
main() {
    [ "$(uname -s)" = Darwin ] || fail "Tic is a macOS app."
    [ "$(uname -m)" = arm64 ] || fail "Tic needs a Mac with Apple silicon."
    [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || fail "Tic needs macOS 14 (Sonoma) or later."

    # Standard (non-admin) accounts can't write to /Applications; use ~/Applications instead.
    dest=${TIC_DEST:-/Applications}
    if [ -z "${TIC_DEST:-}" ] && [ ! -w /Applications ]; then
        dest="$HOME/Applications"
    fi
    mkdir -p "$dest"
    [ -w "$dest" ] || fail "can't write to $dest."
    app="$dest/Tic.app"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    echo "Downloading Tic…"
    base=https://github.com/kasvith/tic/releases/latest/download
    curl -fsSL "$base/Tic.zip" -o "$tmp/Tic.zip"
    curl -fsSL "$base/Tic.zip.sha256" -o "$tmp/Tic.zip.sha256"
    (cd "$tmp" && shasum -a 256 -c Tic.zip.sha256 >/dev/null 2>&1) || fail "the download didn't match its checksum."
    ditto -x -k "$tmp/Tic.zip" "$tmp/new"
    [ -d "$tmp/new/Tic.app" ] || fail "the download didn't contain Tic.app."

    # Quit only the copy being replaced. Anchored so it matches the app itself, not `Tic --mcp`
    # helpers that AI clients run (or their wrappers). Notes are saved as you go, so nothing is lost.
    running="^$app/Contents/MacOS/Tic\$"
    if pgrep -f "$running" >/dev/null; then
        echo "Quitting Tic…"
        pkill -f "$running" || true
        i=0
        while pgrep -f "$running" >/dev/null && [ "$i" -lt 50 ]; do
            sleep 0.2
            i=$((i + 1))
        done
    fi

    # Swap: the old copy goes into the temp folder (removed on exit), restored if the move fails.
    [ -e "$app" ] && mv "$app" "$tmp/old.app"
    if ! mv "$tmp/new/Tic.app" "$app"; then
        [ -e "$tmp/old.app" ] && mv "$tmp/old.app" "$app"
        fail "couldn't move Tic.app into $dest."
    fi

    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || true)
    echo "Installed Tic ${version:+v$version }to $dest"
    open "$app"
}

main "$@"
