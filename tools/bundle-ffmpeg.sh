#!/bin/sh
# Xcode "Bundle ffmpeg" build phase for AVSyncPatternMaker.
# Copies Vendor/macos/ffmpeg into the app's Resources, fetching it first if missing.
# Never fails the build: without ffmpeg the app simply offers no DNxHR output.
set -u

SRC="$SRCROOT/Vendor/macos/ffmpeg"
DEST_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
DEST="$DEST_DIR/ffmpeg"

if [ ! -x "$SRC" ]; then
  echo "note: fetching static ffmpeg into Vendor/macos (first build only)"
  "$SRCROOT/tools/fetch-ffmpeg-macos.sh" || echo "warning: ffmpeg not bundled; DNxHR export will be unavailable unless Homebrew ffmpeg is installed"
fi

if [ -x "$SRC" ]; then
  mkdir -p "$DEST_DIR"
  cp -f "$SRC" "$DEST"
  chmod +x "$DEST"
  xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true
  # Ad-hoc sign so the hardened-runtime app can launch it on any Mac it is copied to.
  codesign --force --sign - --options runtime --timestamp=none "$DEST" 2>/dev/null \
    || codesign --force --sign - "$DEST" 2>/dev/null || true
  echo "bundled $("$DEST" -version 2>/dev/null | head -n 1)"
fi
exit 0
