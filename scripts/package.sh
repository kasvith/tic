#!/bin/bash
#
# Builds a release Tic.app bundle (Dock identity, icon, bundle id com.kasvith.tic) into dist/.
# Usage: scripts/package.sh [--open]
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tic"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "▸ Building release…"
swift build -c release
RELEASE_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$RELEASE_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Packaging/Info.plist"   "$APP/Contents/Info.plist"
cp "Assets/AppIcon/Tic.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

bundles_found=0

# SwiftPM resource bundle(s) (menu-bar icon, dependency privacy manifests, etc.).
# Keep them in Contents/Resources, which is the signed app-bundle resource area.
for bundle in "$RELEASE_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    bundles_found=1
    cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ "$bundles_found" -eq 0 ]; then
    echo "error: no SwiftPM resource bundles found in $RELEASE_DIR" >&2
    exit 1
fi

if [ ! -f "$APP/Contents/Resources/Tic_Tic.bundle/MenuBarIcon.png" ]; then
    echo "error: missing packaged menu bar icon bundle" >&2
    exit 1
fi

if [ -n "${VERSION:-}" ]; then
    echo "▸ Stamping version ${VERSION}…"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
fi

echo "▸ Code signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "▸ Verifying signature…"
codesign --verify --strict "$APP"

echo "✓ Built $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /' || true

if [[ "${1:-}" == "--open" ]]; then
    echo "▸ Launching…"
    open "$APP"
fi
