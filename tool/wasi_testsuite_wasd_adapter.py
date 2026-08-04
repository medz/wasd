import os
import re
import shlex
from pathlib import Path
from typing import Dict, List, Optional, Tuple


DART = shlex.split(os.getenv("DART", "dart"), posix=os.name != "nt")
_REPO_ROOT = Path(__file__).resolve().parents[1]
_P1_RUNNER = _REPO_ROOT / "tool" / "wasi_testsuite_preview1_runner.dart"
_P2_RUNNER = _REPO_ROOT / "tool" / "wasi_testsuite_preview2_component_runner.dart"
_P3_RUNNER = _REPO_ROOT / "tool" / "wasi_testsuite_preview3_component_runner.dart"


def get_name() -> str:
    return "wasd"


def get_version() -> str:
    try:
        manifest = (_REPO_ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    except OSError:
        return "unknown"
    match = re.search(r"^version:\s*(\S+)", manifest, re.MULTILINE)
    return match.group(1) if match else "unknown"


def get_wasi_versions() -> List[str]:
    return ["wasm32-wasip1", "wasm32-wasip2", "wasm32-wasip3"]


def get_wasi_worlds() -> List[str]:
    return ["wasi:cli/command", "wasi:http/service"]


def get_timeout_seconds() -> float:
    return 30.0


def compute_argv(
    test_path: str,
    args_env_root: Tuple[List[str], Dict[str, str], Optional[str]],
    proposals: List[str],
    wasi_world: str,
    wasi_version: str,
) -> List[str]:
    if wasi_version not in {
        "wasm32-wasip1",
        "wasm32-wasip2",
        "wasm32-wasip3",
    }:
        raise ValueError(f"unsupported WASI version for wasd adapter: {wasi_version}")
    if wasi_world not in {"wasi:cli/command", "wasi:http/service"}:
        raise ValueError(f"unsupported WASI world for wasd adapter: {wasi_world}")
    if wasi_version != "wasm32-wasip3" and wasi_world != "wasi:cli/command":
        raise ValueError(
            f"unsupported WASI world for {wasi_version}: {wasi_world}"
        )

    args, env, root = args_env_root
    argv: List[str] = []
    argv += DART
    argv += [str(_runner_for(wasi_version))]
    if wasi_version == "wasm32-wasip3":
        argv += ["--world", wasi_world]
        for proposal in proposals:
            argv += ["--proposal", proposal]
    for key, value in env.items():
        argv += ["--env", f"{key}={value}"]
    if root:
        dir_option = "--copy-dir" if wasi_version == "wasm32-wasip3" else "--dir"
        argv += [dir_option, f"{root}::/"]
    argv += [test_path]
    argv += args
    return argv


def _runner_for(wasi_version: str) -> Path:
    if wasi_version == "wasm32-wasip1":
        return _P1_RUNNER
    if wasi_version == "wasm32-wasip2":
        return _P2_RUNNER
    if wasi_version == "wasm32-wasip3":
        return _P3_RUNNER
    raise ValueError(f"unsupported WASI version for wasd adapter: {wasi_version}")
