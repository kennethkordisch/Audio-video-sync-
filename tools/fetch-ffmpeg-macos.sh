#!/bin/sh
# Downloads a static macOS ffmpeg binary for this Mac's architecture into Vendor/macos/ffmpeg.
# Run once (or let the Xcode build phase run it). The binary is gitignored.
#
# Sources (static builds, LGPL/GPL per their pages):
#   arm64 / x86_64 : https://ffmpeg.martin-riedl.de  (per-arch static builds)
#   fallback x86_64: https://evermeet.cx/ffmpeg       (runs on Apple silicon through Rosetta)
# You can also drop your own ffmpeg binary at Vendor/macos/ffmpeg and nothing is downloaded.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/Vendor/macos"
DEST="$DEST_DIR/ffmpeg"
mkdir -p "$DEST_DIR"

if [ -x "$DEST" ]; then
  echo "ffmpeg already present at $DEST"
  exit 0
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  PRIMARY="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip" ;;
  x86_64) PRIMARY="https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip" ;;
  *) echo "unsupported architecture $ARCH" >&2; exit 1 ;;
esac
FALLBACK="https://evermeet.cx/ffmpeg/getrelease/zip"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() {
  url="$1"
  echo "Downloading $url"
  curl -fsSL --retry 3 -o "$TMP/ffmpeg.zip" "$url" || return 1
  (cd "$TMP" && unzip -oq ffmpeg.zip) || return 1
  BIN="$(find "$TMP" -type f -name ffmpeg | head -n 1)"
  [ -n "$BIN" ] || return 1
  cp "$BIN" "$DEST"
  chmod +x "$DEST"
  xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true
  "$DEST" -version >/dev/null 2>&1 || return 1
  return 0
}

if fetch "$PRIMARY" || fetch "$FALLBACK"; then
  echo "Installed $("$DEST" -version | head -n 1) -> $DEST"
else
  rm -f "$DEST"
  echo "Could not download ffmpeg. Put a static macOS ffmpeg binary at $DEST manually." >&2
  exit 1
fi
