#!/bin/bash
#
# Builds a release Tic.app bundle (Dock identity, icon, bundle id com.kasvith.tic) into dist/.
# Usage: scripts/package.sh [--open]
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tic"
RELEASE_DIR=".build/release"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "▸ Building release…"
swift build -c release

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$RELEASE_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Packaging/Info.plist"   "$APP/Contents/Info.plist"
cp "Assets/AppIcon/Tic.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundle(s) (menu-bar icon, etc.) so Bundle.module resolves inside the .app.
for bundle in "$RELEASE_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ -n "${VERSION:-}" ]; then
    echo "▸ Stamping version ${VERSION}…"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
fi

echo "▸ Code signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "✓ Built $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /' || true

if [[ "${1:-}" == "--open" ]]; then
    echo "▸ Launching…"
    open "$APP"
fi
