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

  if [[ -z "$digest" || "$digest" == "null" ]]; then
    echo "warning: no digest provided for $(basename "$file"), skipping checksum verification" >&2
    return 0
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
    exit 1
  fi
}

fetch_release_json() {
  local repo="$1"
  local tag="$2"
  local output="$3"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/tags/${tag}" -o "$output"
}

pick_asset() {
  local release_json="$1"
  shift
  local candidate line
  for candidate in "$@"; do
    line="$(jq -r --arg name "$candidate" '.assets[] | select(.name == $name) | [.name, .browser_download_url, (.digest // "")] | @tsv' "$release_json" | head -n1)"
    if [[ -n "$line" ]]; then
      echo "$line"
      return 0
    fi
  done
  return 1
}

download_asset() {
  local name="$1"
  local url="$2"
  local digest="$3"
  local output="$4"
  curl -fsSL "$url" -o "$output"
  verify_digest "$output" "$digest"
  echo "downloaded: $name"
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

if [[ "$MODE" == "check" ]]; then
  if is_ready; then
    wabt_installed="$("$BIN_DIR/wasm-interp" --version 2>/dev/null | head -n1 || true)"
    wasm_tools_installed="$("$BIN_DIR/wasm-tools" --version 2>/dev/null | head -n1 || true)"
    if [[ "$wabt_installed" != *"$WABT_VERSION"* ]]; then
      echo "toolchains: version mismatch" >&2
      echo "expected wabt version: $WABT_VERSION" >&2
      echo "actual wasm-interp --version: ${wabt_installed:-<empty>}" >&2
      exit 1
    fi
    if [[ "$wasm_tools_installed" != *"$WASM_TOOLS_VERSION"* ]]; then
      echo "toolchains: version mismatch" >&2
      echo "expected wasm-tools version: $WASM_TOOLS_VERSION" >&2
      echo "actual wasm-tools --version: ${wasm_tools_installed:-<empty>}" >&2
      exit 1
    fi
    echo "toolchains: ok"
    "$BIN_DIR/wasm-interp" --version || true
    "$BIN_DIR/wast2json" --version || true
    "$BIN_DIR/wasm-tools" --version || true
    exit 0
  fi
  echo "toolchains: missing"
  exit 1
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

WABT_CANDIDATES=()
WASM_TOOLS_CANDIDATES=()

case "$PLATFORM" in
  macos-aarch64)
    WABT_CANDIDATES=(
      "wabt-${WABT_VERSION}-macos-arm64.tar.gz"
      "wabt-${WABT_VERSION}-macos-14.tar.gz"
    )
    WASM_TOOLS_CANDIDATES=("wasm-tools-${WASM_TOOLS_VERSION}-aarch64-macos.tar.gz")
    ;;
  macos-x86_64)
    WABT_CANDIDATES=(
      "wabt-${WABT_VERSION}-macos-x64.tar.gz"
      "wabt-${WABT_VERSION}-macos-x86_64.tar.gz"
      "wabt-${WABT_VERSION}-macos-14.tar.gz"
    )
    WASM_TOOLS_CANDIDATES=("wasm-tools-${WASM_TOOLS_VERSION}-x86_64-macos.tar.gz")
    ;;
  linux-x86_64)
    WABT_CANDIDATES=(
      "wabt-${WABT_VERSION}-linux-x64.tar.gz"
      "wabt-${WABT_VERSION}-linux-x86_64.tar.gz"
      "wabt-${WABT_VERSION}-ubuntu-20.04.tar.gz"
    )
    WASM_TOOLS_CANDIDATES=("wasm-tools-${WASM_TOOLS_VERSION}-x86_64-linux.tar.gz")
    ;;
  linux-aarch64)
    WABT_CANDIDATES=(
      "wabt-${WABT_VERSION}-linux-arm64.tar.gz"
      "wabt-${WABT_VERSION}-linux-aarch64.tar.gz"
    )
    WASM_TOOLS_CANDIDATES=("wasm-tools-${WASM_TOOLS_VERSION}-aarch64-linux.tar.gz")
    ;;
  *)
    echo "Unsupported platform: $PLATFORM" >&2
    exit 1
    ;;
esac

WORK_DIR="$TOOLCHAIN_DIR/.downloads"
mkdir -p "$WORK_DIR"

WABT_RELEASE_JSON="$WORK_DIR/wabt-${WABT_VERSION}.release.json"
WASM_TOOLS_RELEASE_JSON="$WORK_DIR/wasm-tools-${WASM_TOOLS_VERSION}.release.json"
fetch_release_json "WebAssembly/wabt" "${WABT_VERSION}" "$WABT_RELEASE_JSON"
fetch_release_json "bytecodealliance/wasm-tools" "v${WASM_TOOLS_VERSION}" "$WASM_TOOLS_RELEASE_JSON"

WABT_ASSET_LINE="$(pick_asset "$WABT_RELEASE_JSON" "${WABT_CANDIDATES[@]}")" || {
  echo "Unable to find a matching wabt asset for platform: $PLATFORM" >&2
  exit 1
}
IFS=$'\t' read -r WABT_ASSET_NAME WABT_URL WABT_DIGEST <<<"$WABT_ASSET_LINE"

WASM_TOOLS_ASSET_LINE="$(pick_asset "$WASM_TOOLS_RELEASE_JSON" "${WASM_TOOLS_CANDIDATES[@]}")" || {
  echo "Unable to find a matching wasm-tools asset for platform: $PLATFORM" >&2
  exit 1
}
IFS=$'\t' read -r WASM_TOOLS_ASSET_NAME WASM_TOOLS_URL WASM_TOOLS_DIGEST <<<"$WASM_TOOLS_ASSET_LINE"

WABT_ARCHIVE="$WORK_DIR/$WABT_ASSET_NAME"
WABT_EXTRACT_DIR="$TOOLCHAIN_DIR/wabt-${WABT_VERSION}"
rm -rf "$WABT_EXTRACT_DIR"
download_asset "$WABT_ASSET_NAME" "$WABT_URL" "$WABT_DIGEST" "$WABT_ARCHIVE"
mkdir -p "$WABT_EXTRACT_DIR"
tar -xzf "$WABT_ARCHIVE" -C "$WABT_EXTRACT_DIR" --strip-components=1
ln -sf "$WABT_EXTRACT_DIR/bin/wasm-interp" "$BIN_DIR/wasm-interp"
ln -sf "$WABT_EXTRACT_DIR/bin/wasm-validate" "$BIN_DIR/wasm-validate"
ln -sf "$WABT_EXTRACT_DIR/bin/wat2wasm" "$BIN_DIR/wat2wasm"
ln -sf "$WABT_EXTRACT_DIR/bin/wast2json" "$BIN_DIR/wast2json"

WASM_TOOLS_ARCHIVE="$WORK_DIR/$WASM_TOOLS_ASSET_NAME"
WASM_TOOLS_EXTRACT_DIR="$TOOLCHAIN_DIR/wasm-tools-${WASM_TOOLS_VERSION}"
rm -rf "$WASM_TOOLS_EXTRACT_DIR"
download_asset "$WASM_TOOLS_ASSET_NAME" "$WASM_TOOLS_URL" "$WASM_TOOLS_DIGEST" "$WASM_TOOLS_ARCHIVE"
mkdir -p "$WASM_TOOLS_EXTRACT_DIR"
tar -xzf "$WASM_TOOLS_ARCHIVE" -C "$WASM_TOOLS_EXTRACT_DIR"
WASM_TOOLS_BIN_PATH="$(find "$WASM_TOOLS_EXTRACT_DIR" -type f -name wasm-tools -print -quit)"
if [[ -n "${WASM_TOOLS_BIN_PATH:-}" ]]; then
  ln -sf "$WASM_TOOLS_BIN_PATH" "$BIN_DIR/wasm-tools"
fi

if is_ready; then
  echo "toolchains: installed"
  "$BIN_DIR/wasm-interp" --version || true
  "$BIN_DIR/wast2json" --version || true
  "$BIN_DIR/wasm-tools" --version || true
  exit 0
fi

echo "toolchains: partially installed" >&2
exit 1
