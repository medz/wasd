#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_DIR="$ROOT_DIR/.toolchains"
BIN_DIR="$TOOLCHAIN_DIR/bin"
WABT_VERSION="1.0.37"
WASM_TOOLS_VERSION="1.226.0"

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
  [[ -x "$BIN_DIR/wasm-interp" ]] && [[ -x "$BIN_DIR/wasm-tools" ]]
}

if [[ "$MODE" == "check" ]]; then
  if is_ready; then
    echo "toolchains: ok"
    "$BIN_DIR/wasm-interp" --version || true
    "$BIN_DIR/wasm-tools" --version || true
    exit 0
  fi
  echo "toolchains: missing"
  exit 1
fi

need_cmd curl
need_cmd tar

PLATFORM="$(platform_key)"
if [[ "$PLATFORM" == "unsupported" ]]; then
  echo "Unsupported platform for auto-install: $(uname -s) $(uname -m)" >&2
  echo "Please install wabt/wasm-tools manually and place binaries under $BIN_DIR" >&2
  exit 1
fi

WABT_URL=""
WASM_TOOLS_URL=""

case "$PLATFORM" in
  macos-aarch64)
    WABT_URL="https://github.com/WebAssembly/wabt/releases/download/${WABT_VERSION}/wabt-${WABT_VERSION}-macos-14.tar.gz"
    WASM_TOOLS_URL="https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/wasm-tools-${WASM_TOOLS_VERSION}-aarch64-macos.tar.gz"
    ;;
  macos-x86_64)
    WABT_URL="https://github.com/WebAssembly/wabt/releases/download/${WABT_VERSION}/wabt-${WABT_VERSION}-macos-14.tar.gz"
    WASM_TOOLS_URL="https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/wasm-tools-${WASM_TOOLS_VERSION}-x86_64-macos.tar.gz"
    ;;
  linux-x86_64)
    WABT_URL="https://github.com/WebAssembly/wabt/releases/download/${WABT_VERSION}/wabt-${WABT_VERSION}-ubuntu-20.04.tar.gz"
    WASM_TOOLS_URL="https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/wasm-tools-${WASM_TOOLS_VERSION}-x86_64-linux.tar.gz"
    ;;
  linux-aarch64)
    echo "No official wabt linux arm64 binary in pinned release ${WABT_VERSION}." >&2
    echo "Install wabt manually and place binaries under $BIN_DIR." >&2
    WABT_URL=""
    WASM_TOOLS_URL="https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/wasm-tools-${WASM_TOOLS_VERSION}-aarch64-linux.tar.gz"
    ;;
  *)
    echo "Unsupported platform: $PLATFORM" >&2
    exit 1
    ;;
esac

WORK_DIR="$TOOLCHAIN_DIR/.downloads"
mkdir -p "$WORK_DIR"

if [[ -n "$WABT_URL" ]]; then
  WABT_ARCHIVE="$WORK_DIR/wabt-${WABT_VERSION}.tar.gz"
  WABT_EXTRACT_DIR="$TOOLCHAIN_DIR/wabt-${WABT_VERSION}"
  rm -rf "$WABT_EXTRACT_DIR"
  curl -fsSL "$WABT_URL" -o "$WABT_ARCHIVE"
  mkdir -p "$WABT_EXTRACT_DIR"
  tar -xzf "$WABT_ARCHIVE" -C "$WABT_EXTRACT_DIR" --strip-components=1
  ln -sf "$WABT_EXTRACT_DIR/bin/wasm-interp" "$BIN_DIR/wasm-interp"
  ln -sf "$WABT_EXTRACT_DIR/bin/wasm-validate" "$BIN_DIR/wasm-validate"
  ln -sf "$WABT_EXTRACT_DIR/bin/wat2wasm" "$BIN_DIR/wat2wasm"
fi

if [[ -n "$WASM_TOOLS_URL" ]]; then
  WASM_TOOLS_ARCHIVE="$WORK_DIR/wasm-tools-${WASM_TOOLS_VERSION}.tar.gz"
  WASM_TOOLS_EXTRACT_DIR="$TOOLCHAIN_DIR/wasm-tools-${WASM_TOOLS_VERSION}"
  rm -rf "$WASM_TOOLS_EXTRACT_DIR"
  curl -fsSL "$WASM_TOOLS_URL" -o "$WASM_TOOLS_ARCHIVE"
  mkdir -p "$WASM_TOOLS_EXTRACT_DIR"
  tar -xzf "$WASM_TOOLS_ARCHIVE" -C "$WASM_TOOLS_EXTRACT_DIR"
  WASM_TOOLS_BIN_PATH="$(find "$WASM_TOOLS_EXTRACT_DIR" -type f -name wasm-tools -print -quit)"
  if [[ -n "${WASM_TOOLS_BIN_PATH:-}" ]]; then
    ln -sf "$WASM_TOOLS_BIN_PATH" "$BIN_DIR/wasm-tools"
  fi
fi

if is_ready; then
  echo "toolchains: installed"
  "$BIN_DIR/wasm-interp" --version || true
  "$BIN_DIR/wasm-tools" --version || true
  exit 0
fi

echo "toolchains: partially installed" >&2
exit 1
