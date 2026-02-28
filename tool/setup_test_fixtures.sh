#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$ROOT_DIR/test/fixtures"
DOOM_FIXTURE_DIR="$FIXTURES_DIR/doom"
COMMUNITY_FIXTURE_DIR="$FIXTURES_DIR/community"

DOOM_WASM_URL="https://github.com/malcolmstill/zware-doom/blob/master/src/doom.wasm?raw=1"
FREEDOOM_ZIP_URL="https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
TINYGO_EXAMPLE_REF="release"
TINYGO_EXAMPLE_URL="https://raw.githubusercontent.com/tinygo-org/tinygo/${TINYGO_EXAMPLE_REF}/src/examples/wasm/main/main.go"

DO_SETUP_DOOM=1
DO_SETUP_COMMUNITY=1
WITH_TINYGO=0

usage() {
  cat <<'EOF'
Usage: tool/setup_test_fixtures.sh [options]

Options:
  --doom-only                 Setup Doom fixtures only.
  --community-only            Setup community wasm fixtures only.
  --with-tinygo               Build TinyGo fixture from tinygo-org/tinygo official example source (implies community setup).
  -h, --help                  Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --doom-only)
      DO_SETUP_DOOM=1
      DO_SETUP_COMMUNITY=0
      ;;
    --community-only)
      DO_SETUP_DOOM=0
      DO_SETUP_COMMUNITY=1
      ;;
    --with-tinygo)
      WITH_TINYGO=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ "$WITH_TINYGO" -eq 1 ]]; then
  DO_SETUP_COMMUNITY=1
fi

setup_doom_fixture() {
  mkdir -p "$DOOM_FIXTURE_DIR"
  local freedoom_zip_path="$DOOM_FIXTURE_DIR/freedoom-0.13.0.zip"
  local freedoom_wad_path="$DOOM_FIXTURE_DIR/freedoom1.wad"
  local doom_wad_path="$DOOM_FIXTURE_DIR/doom1.wad"
  local doom_wasm_path="$DOOM_FIXTURE_DIR/doom.wasm"

  if [[ ! -f "$doom_wasm_path" ]]; then
    echo "Downloading Doom wasm fixture ..."
    curl -L --fail "$DOOM_WASM_URL" -o "$doom_wasm_path"
  fi

  if [[ ! -f "$freedoom_wad_path" ]]; then
    if [[ ! -f "$freedoom_zip_path" ]]; then
      echo "Downloading Freedoom IWAD fixture ..."
      curl -L --fail "$FREEDOOM_ZIP_URL" -o "$freedoom_zip_path"
    fi
    echo "Extracting freedoom1.wad ..."
    unzip -j -o "$freedoom_zip_path" "freedoom-0.13.0/freedoom1.wad" -d "$DOOM_FIXTURE_DIR"
  fi

  if [[ ! -f "$doom_wad_path" ]]; then
    cp -f "$freedoom_wad_path" "$doom_wad_path"
  fi

  echo "Doom fixtures ready:"
  echo "  $doom_wasm_path"
  echo "  $doom_wad_path"
}

setup_go_fixture() {
  if ! command -v go >/dev/null 2>&1; then
    echo "Skipping Go fixture: go not found in PATH." >&2
    return
  fi

  mkdir -p "$COMMUNITY_FIXTURE_DIR"
  local go_src="$FIXTURES_DIR/src/go_hello/main.go"
  local go_out="$COMMUNITY_FIXTURE_DIR/go_hello_wasip1.wasm"
  echo "Building Go WASI fixture ..."
  GOOS=wasip1 GOARCH=wasm go build -trimpath -ldflags='-s -w' -o "$go_out" "$go_src"
  echo "  $go_out"
}

setup_tinygo_fixture() {
  if [[ "$WITH_TINYGO" -ne 1 ]]; then
    return
  fi

  if ! command -v tinygo >/dev/null 2>&1; then
    echo "Skipping TinyGo fixture: tinygo not found in PATH." >&2
    return
  fi

  mkdir -p "$COMMUNITY_FIXTURE_DIR"
  local tinygo_src_dir="$FIXTURES_DIR/src/tinygo_org_wasm_main"
  local tinygo_src="$tinygo_src_dir/main.go"
  local tinygo_out="$COMMUNITY_FIXTURE_DIR/tinygo_hello_wasi.wasm"
  mkdir -p "$tinygo_src_dir"
  if [[ ! -f "$tinygo_src" ]]; then
    echo "Fetching TinyGo official example source ..."
    curl -L --fail "$TINYGO_EXAMPLE_URL" -o "$tinygo_src"
  else
    echo "TinyGo official example source already present, skipping download."
  fi
  echo "Building TinyGo WASI fixture ..."
  tinygo build -target wasi -opt 2 -o "$tinygo_out" "$tinygo_src"
  echo "  $tinygo_out"
}

if [[ "$DO_SETUP_DOOM" -eq 1 ]]; then
  setup_doom_fixture
fi

if [[ "$DO_SETUP_COMMUNITY" -eq 1 ]]; then
  setup_go_fixture
  setup_tinygo_fixture
fi

echo "Fixture setup complete."
