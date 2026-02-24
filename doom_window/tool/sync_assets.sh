#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT_DIR/../example/doom"
DST_DIR="$ROOT_DIR/assets/doom"

mkdir -p "$DST_DIR"

if [[ ! -f "$SRC_DIR/doom.wasm" || ( ! -f "$SRC_DIR/doom1.wad" && ! -f "$SRC_DIR/freedoom1.wad" ) ]]; then
  echo "Source assets missing. Running setup script..."
  "$SRC_DIR/setup_assets.sh"
fi

cp -f "$SRC_DIR/doom.wasm" "$DST_DIR/doom.wasm"
if [[ -f "$SRC_DIR/doom1.wad" ]]; then
  cp -f "$SRC_DIR/doom1.wad" "$DST_DIR/doom1.wad"
else
  cp -f "$SRC_DIR/freedoom1.wad" "$DST_DIR/doom1.wad"
fi

echo "Synced assets:"
echo "  $DST_DIR/doom.wasm"
echo "  $DST_DIR/doom1.wad"
