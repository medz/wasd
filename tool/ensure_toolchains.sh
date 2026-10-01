#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_DIR="$ROOT_DIR/.toolchains"
BIN_DIR="$TOOLCHAIN_DIR/bin"
LOCK_FILE="$ROOT_DIR/tool/toolchain.lock.json"
WABT_VERSION="${WABT_VERSION:-}"
WASM_TOOLS_VERSION="${WASM_TOOLS_VERSION:-}"

MODE="install"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ "${1:-}" == "--help" ]]; then
  echo "Usage: tool/ensure_toolchains.sh [--check]"
  exit 0
fi

mkdir -p "$TOOLCHAIN_DIR" "$BIN_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

load_locked_versions() {
  if [[ ! -f "$LOCK_FILE" ]]; then
    echo "Missing toolchain lock file: $LOCK_FILE" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Missing required command: jq (needed to read $LOCK_FILE)" >&2
    exit 1
  fi

  local locked_wabt locked_wasm_tools
  locked_wabt="$(jq -r '.wabt.version // ""' "$LOCK_FILE")"
  locked_wasm_tools="$(jq -r '.wasm_tools.version // ""' "$LOCK_FILE")"
  if [[ -z "$locked_wabt" || -z "$locked_wasm_tools" ]]; then
    echo "Invalid toolchain lock file (missing versions): $LOCK_FILE" >&2
    exit 1
  fi

  if [[ -z "$WABT_VERSION" ]]; then
    WABT_VERSION="$locked_wabt"
  fi
  if [[ -z "$WASM_TOOLS_VERSION" ]]; then
    WASM_TOOLS_VERSION="$locked_wasm_tools"
  fi

  if [[ "$WABT_VERSION" != "$locked_wabt" || "$WASM_TOOLS_VERSION" != "$locked_wasm_tools" ]]; then
    echo "Toolchain version drift detected between script/env and lock file." >&2
    echo "lock wabt=$locked_wabt wasm_tools=$locked_wasm_tools" >&2
    echo "script/env wabt=$WABT_VERSION wasm_tools=$WASM_TOOLS_VERSION" >&2
    echo "Sync tool/ensure_toolchains.sh (or env overrides) with $LOCK_FILE." >&2
    exit 1
  fi
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi
  echo "Missing required command: sha256sum or shasum" >&2
  exit 1
}

verify_digest() {
  local file="$1"
  local digest="$2"

  if [[ ! "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    echo "Missing or invalid pinned SHA-256 digest for $(basename "$file")" >&2
    return 1
  fi

  local algo expected actual
  algo="${digest%%:*}"
  expected="${digest#*:}"

  case "$algo" in
    sha256)
      actual="$(sha256_file "$file")"
      ;;
    *)
      echo "Unsupported digest algorithm: $algo" >&2
      exit 1
      ;;
  esac

  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum verification failed for $file" >&2
    echo "expected=$expected" >&2
    echo "actual=$actual" >&2
    return 1
  fi
}

read_locked_asset() {
  local tool="$1"
  local asset name digest
  asset="$(jq -er --arg tool "$tool" --arg platform "$PLATFORM" \
    '.[$tool].assets[$platform] | [.name, .sha256] | @tsv' "$LOCK_FILE")" || {
    echo "Missing pinned official $tool archive for platform: $PLATFORM" >&2
    return 1
  }
  IFS=$'\t' read -r name digest <<<"$asset"
  if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+\.tar\.gz$ ]]; then
    echo "Invalid pinned archive name for $tool: $name" >&2
    return 1
  fi
  if [[ ! "$digest" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Missing or invalid pinned SHA-256 digest for $tool ($PLATFORM)" >&2
    return 1
  fi
  printf '%s\t%s\n' "$name" "$digest"
}

download_asset() {
  local name="$1"
  local url="$2"
  local digest="$3"
  local output="$4"
  if [[ -f "$output" ]]; then
    verify_digest "$output" "$digest"
    echo "verified cached archive: $name"
    return 0
  fi
  local temporary status
  temporary="$(mktemp "${output}.part.XXXXXX")"
  if ! status="$(curl -fsSL -w '%{http_code}' "$url" -o "$temporary")"; then
    echo "Official archive request failed: $url (HTTP ${status:-000})" >&2
    rm -f "$temporary"
    return 1
  fi
  if ! verify_digest "$temporary" "$digest"; then
    rm -f "$temporary"
    return 1
  fi
  mv "$temporary" "$output"
  echo "downloaded and verified: $name"
}

platform_key() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin)
      case "$arch" in
        arm64) echo "macos-aarch64" ;;
        x86_64) echo "macos-x86_64" ;;
        *) echo "unsupported" ;;
      esac
      ;;
    Linux)
      case "$arch" in
        x86_64) echo "linux-x86_64" ;;
        aarch64|arm64) echo "linux-aarch64" ;;
        *) echo "unsupported" ;;
      esac
      ;;
    *) echo "unsupported" ;;
  esac
}

is_ready() {
  [[ -x "$BIN_DIR/wasm-interp" ]] &&
    [[ -x "$BIN_DIR/wast2json" ]] &&
    [[ -x "$BIN_DIR/wasm-tools" ]]
}

load_locked_versions

check_installed_versions() {
  if ! is_ready; then
    echo "toolchains: missing" >&2
    return 1
  fi
  local wabt_installed wasm_tools_installed
  wabt_installed="$("$BIN_DIR/wasm-interp" --version 2>/dev/null | head -n1)"
  wasm_tools_installed="$("$BIN_DIR/wasm-tools" --version 2>/dev/null | head -n1)"
  if [[ "$wabt_installed" != "$WABT_VERSION" ||
        "$wasm_tools_installed" != "wasm-tools $WASM_TOOLS_VERSION "* ]]; then
    echo "toolchains: version mismatch" >&2
    echo "expected wabt=$WABT_VERSION wasm-tools=$WASM_TOOLS_VERSION" >&2
    echo "actual wabt=$wabt_installed wasm-tools=$wasm_tools_installed" >&2
    return 1
  fi
  echo "toolchains: ok"
  "$BIN_DIR/wasm-interp" --version
  "$BIN_DIR/wast2json" --version
  "$BIN_DIR/wasm-tools" --version
}

if [[ "$MODE" == "check" ]]; then
  check_installed_versions
  exit 0
fi

need_cmd curl
need_cmd tar
need_cmd jq

PLATFORM="$(platform_key)"
if [[ "$PLATFORM" == "unsupported" ]]; then
  echo "Unsupported platform for auto-install: $(uname -s) $(uname -m)" >&2
  echo "Please install wabt/wasm-tools manually and place binaries under $BIN_DIR" >&2
  exit 1
fi

# Fixed official release names and SHA-256 digests come from the reviewed lock.
# Installing does not need the GitHub REST API or an access token.
WABT_ASSET_LINE="$(read_locked_asset wabt)"
WASM_TOOLS_ASSET_LINE="$(read_locked_asset wasm_tools)"
IFS=$'\t' read -r WABT_ASSET_NAME WABT_SHA256 <<<"$WABT_ASSET_LINE"
IFS=$'\t' read -r WASM_TOOLS_ASSET_NAME WASM_TOOLS_SHA256 <<<"$WASM_TOOLS_ASSET_LINE"
WABT_URL="https://github.com/WebAssembly/wabt/releases/download/${WABT_VERSION}/${WABT_ASSET_NAME}"
WASM_TOOLS_URL="https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/${WASM_TOOLS_ASSET_NAME}"
WABT_DIGEST="sha256:$WABT_SHA256"
WASM_TOOLS_DIGEST="sha256:$WASM_TOOLS_SHA256"
WORK_DIR="$TOOLCHAIN_DIR/.downloads"
mkdir -p "$WORK_DIR"

WABT_ARCHIVE="$WORK_DIR/$WABT_ASSET_NAME"
WABT_EXTRACT_DIR="$TOOLCHAIN_DIR/wabt-${WABT_VERSION}"
download_asset "$WABT_ASSET_NAME" "$WABT_URL" "$WABT_DIGEST" "$WABT_ARCHIVE"
rm -rf "$WABT_EXTRACT_DIR"
mkdir -p "$WABT_EXTRACT_DIR"
tar -xzf "$WABT_ARCHIVE" -C "$WABT_EXTRACT_DIR" --strip-components=1
ln -sf "$WABT_EXTRACT_DIR/bin/wasm-interp" "$BIN_DIR/wasm-interp"
ln -sf "$WABT_EXTRACT_DIR/bin/wasm-validate" "$BIN_DIR/wasm-validate"
ln -sf "$WABT_EXTRACT_DIR/bin/wat2wasm" "$BIN_DIR/wat2wasm"
ln -sf "$WABT_EXTRACT_DIR/bin/wast2json" "$BIN_DIR/wast2json"

WASM_TOOLS_ARCHIVE="$WORK_DIR/$WASM_TOOLS_ASSET_NAME"
WASM_TOOLS_EXTRACT_DIR="$TOOLCHAIN_DIR/wasm-tools-${WASM_TOOLS_VERSION}"
download_asset "$WASM_TOOLS_ASSET_NAME" "$WASM_TOOLS_URL" "$WASM_TOOLS_DIGEST" "$WASM_TOOLS_ARCHIVE"
rm -rf "$WASM_TOOLS_EXTRACT_DIR"
mkdir -p "$WASM_TOOLS_EXTRACT_DIR"
tar -xzf "$WASM_TOOLS_ARCHIVE" -C "$WASM_TOOLS_EXTRACT_DIR"
WASM_TOOLS_BIN_PATH="$(find "$WASM_TOOLS_EXTRACT_DIR" -type f -name wasm-tools -print -quit)"
if [[ -n "${WASM_TOOLS_BIN_PATH:-}" ]]; then
  ln -sf "$WASM_TOOLS_BIN_PATH" "$BIN_DIR/wasm-tools"
fi

check_installed_versions
