#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/assets/doom"
DOOM_WASM_URL="https://github.com/malcolmstill/zware-doom/blob/master/src/doom.wasm?raw=1"
FREEDOOM_ZIP_URL="https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
FREEDOOM_ZIP_PATH="$ASSETS_DIR/freedoom-0.13.0.zip"

mkdir -p "$ASSETS_DIR"

if [[ ! -f "$ASSETS_DIR/doom.wasm" ]]; then
  echo "Downloading doom.wasm ..."
  curl -L --fail "$DOOM_WASM_URL" -o "$ASSETS_DIR/doom.wasm"
fi

if [[ ! -f "$ASSETS_DIR/freedoom1.wad" ]]; then
  if [[ ! -f "$FREEDOOM_ZIP_PATH" ]]; then
    echo "Downloading Freedoom IWAD bundle ..."
    curl -L --fail "$FREEDOOM_ZIP_URL" -o "$FREEDOOM_ZIP_PATH"
  fi
  echo "Extracting freedoom1.wad ..."
  unzip -j -o "$FREEDOOM_ZIP_PATH" "freedoom-0.13.0/freedoom1.wad" -d "$ASSETS_DIR"
fi

if [[ ! -f "$ASSETS_DIR/doom1.wad" ]]; then
  cp -f "$ASSETS_DIR/freedoom1.wad" "$ASSETS_DIR/doom1.wad"
fi

echo "Ready:"
echo "  $ASSETS_DIR/doom.wasm"
echo "  $ASSETS_DIR/doom1.wad"
