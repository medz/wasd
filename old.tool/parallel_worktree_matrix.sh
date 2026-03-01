#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/seven/workspace"
MAIN_WT="$ROOT/wasd"
VM_WT="$ROOT/wasd-wt-core-runtime"
JS_WT="$ROOT/wasd-wt-simd-eh"
WASM_WT="$ROOT/wasd-wt-gc-component"

LOG_DIR="$MAIN_WT/.dart_tool/parallel_matrix"
mkdir -p "$LOG_DIR"

run_lane() {
  local name="$1"
  local wt="$2"
  local target="$3"
  local suite="$4"
  local log="$LOG_DIR/${name}.log"

  (
    set -euo pipefail
    cd "$wt"
    dart run tool/spec_runner.dart \
      --target="$target" \
      --suite="$suite" \
      --strict-proposals \
      >"$log" 2>&1
  ) &
  echo "$!:$name:$log"
}

PIDS=()
PIDS+=("$(run_lane vm_all "$VM_WT" vm all)")
PIDS+=("$(run_lane js_all "$JS_WT" js all)")
PIDS+=("$(run_lane wasm_all "$WASM_WT" wasm all)")

FAILURES=0
for item in "${PIDS[@]}"; do
  IFS=':' read -r pid name log <<<"$item"
  if wait "$pid"; then
    echo "[ok]   $name ($log)"
  else
    echo "[fail] $name ($log)"
    FAILURES=$((FAILURES + 1))
  fi
done

if [[ "$FAILURES" -ne 0 ]]; then
  echo "parallel matrix completed with $FAILURES failure lane(s)"
  exit 1
fi

echo "parallel matrix completed successfully"
