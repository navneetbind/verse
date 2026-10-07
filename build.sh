#!/bin/bash
# Build Verse.app (universal) with the browser extension bundled inside.
#   ./build.sh           build build/Verse.app
#   ./build.sh install   also copy it to ~/Applications and register it with your browsers
#   ./build.sh dmg       also pack build/Verse-<version>.dmg (drag-to-Applications)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/menubar"

# Universal binary: Apple Silicon + Intel.
swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0
BIN=.build/verse-universal
lipo -create -output "$BIN" \
  .build/arm64-apple-macosx/release/verse \
  .build/x86_64-apple-macosx/release/verse

APP="$ROOT/build/Verse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/verse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The extension travels inside the app; first launch copies it somewhere stable.
rsync -a --exclude '.DS_Store' "$ROOT/extension/" "$APP/Contents/Resources/extension/"

# Verse needs no privacy permissions, so an ad-hoc signature is enough.
codesign --force --sign - "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

if [[ "${1:-}" == "dmg" ]]; then
  DMG="$ROOT/build/Verse-$VERSION.dmg"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
  rm -f "$DMG"
  RW=$(mktemp -u).dmg
  hdiutil create -quiet -volname "Verse" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW"
  MOUNT=$(hdiutil attach -nobrowse -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
  SetFile -a C "$MOUNT" 2>/dev/null || true
  hdiutil detach -quiet "$MOUNT"
  hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
  rm -rf "$STAGE" "$RW"
  # leaving build/Verse.app around makes Spotlight index a second copy
  rm -rf "$APP"
  echo "Built $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
  echo "sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
elif [[ "${1:-}" == "install" ]]; then
  # ~/Applications: macOS blocks terminals from modifying /Applications.
  DEST=~/Applications
  if [[ -d /Applications/Verse.app ]]; then
    echo "⚠️  /Applications/Verse.app exists (a DMG install). Delete it in Finder to avoid two copies."
  fi
  pkill -f "Verse.app/Contents/MacOS/verse" 2>/dev/null || true
  mkdir -p "$DEST"
  rm -rf "$DEST/Verse.app"
  cp -R "$APP" "$DEST/"
  rm -rf "$APP"
  "$DEST/Verse.app/Contents/MacOS/verse" --register
  echo "Installed to $DEST/Verse.app"
else
  echo "Built $APP"
fi
