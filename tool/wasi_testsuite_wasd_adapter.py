import os
import shlex
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Tuple


DART = shlex.split(os.getenv("DART", "dart"), posix=os.name != "nt")
_REPO_ROOT = Path(__file__).resolve().parents[1]
_RUNNER = _REPO_ROOT / "tool" / "wasi_testsuite_preview1_runner.dart"


def get_name() -> str:
    return "wasd"


def get_version() -> str:
    result = subprocess.run(
        DART + [str(_RUNNER), "--version"],
        encoding="UTF-8",
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()


def get_wasi_versions() -> List[str]:
    return ["wasm32-wasip1"]


def get_wasi_worlds() -> List[str]:
    return ["wasi:cli/command"]


def compute_argv(
    test_path: str,
    args_env_root: Tuple[List[str], Dict[str, str], Optional[str]],
    proposals: List[str],
    wasi_world: str,
    wasi_version: str,
) -> List[str]:
    if wasi_version != "wasm32-wasip1":
        raise ValueError(f"unsupported WASI version for wasd adapter: {wasi_version}")
    if wasi_world != "wasi:cli/command":
        raise ValueError(f"unsupported WASI world for wasd adapter: {wasi_world}")

    args, env, root = args_env_root
    argv: List[str] = []
    argv += DART
    argv += [str(_RUNNER)]
    for key, value in env.items():
        argv += ["--env", f"{key}={value}"]
    if root:
        argv += ["--dir", f"{root}::/"]
    argv += [test_path]
    argv += args
    return argv
