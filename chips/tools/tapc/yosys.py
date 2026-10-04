"""Running Yosys (the YoWASP WebAssembly build) as a subprocess.

Two things matter here:

  * The YoWASP runtime mounts a fresh temporary directory at /tmp inside the sandbox, so a real file under
    /tmp is invisible to Yosys on Linux. Everything Yosys reads or writes is therefore placed in one working
    directory and referred to by a relative name.
  * The first run compiles the 63 MB wasm module (about 14 s) and caches it. The cache goes inside the virtual
    environment (chips/.venv/cache/yowasp) unless YOWASP_CACHE_DIR is already set, so nothing is written
    outside the repository.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Optional

_RUNNER = "import sys, yowasp_yosys; sys.exit(yowasp_yosys.run_yosys(sys.argv[1:]))"


class YosysError(RuntimeError):
    def __init__(self, message: str, log: str = ""):
        super().__init__(message)
        self.log = log


@dataclass
class YosysRun:
    returncode: int
    log: str            # contents of the -l log file (or stdout when no log file was written)
    seconds: float
    stdout: str = ""


def cache_dir() -> str:
    env = os.environ.get("YOWASP_CACHE_DIR")
    if env:
        return env
    if sys.prefix != sys.base_prefix:                      # inside a virtual environment
        return os.path.join(sys.prefix, "cache", "yowasp")
    return ""


def _env() -> dict:
    env = dict(os.environ)
    cd = cache_dir()
    if cd:
        env["YOWASP_CACHE_DIR"] = cd
    env.pop("YOWASP_MOUNT", None)
    return env


def run_script(script: str, cwd: str, tag: str = "yosys", timeout: Optional[float] = None,
               check: bool = True, timestamps: bool = False) -> YosysRun:
    """Write `script` to <cwd>/<tag>.ys, run it with -q, log to <cwd>/<tag>.log. File names inside the script
    must be relative to cwd. `timeout` kills the process (returncode -9): Yosys's own time limits, such as
    `sat -timeout`, never fire in the WebAssembly build. `timestamps` prefixes every log line with [seconds]."""
    os.makedirs(cwd, exist_ok=True)
    ys = f"{tag}.ys"
    log = f"{tag}.log"
    with open(os.path.join(cwd, ys), "w", encoding="utf-8") as f:
        f.write(script)
    log_path = os.path.join(cwd, log)
    if os.path.exists(log_path):
        os.remove(log_path)
    t0 = time.perf_counter()
    try:
        args = ["-q", "-t"] if timestamps else ["-q"]
        proc = subprocess.run([sys.executable, "-c", _RUNNER, *args, "-l", log, "-s", ys], cwd=cwd, env=_env(),
                              capture_output=True, text=True, timeout=timeout)
        rc, out = proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired as e:
        rc = -9
        out = f"timeout after {timeout} s\n" + ((e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or ""))
    dt = time.perf_counter() - t0
    text = ""
    if os.path.exists(log_path):
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    run = YosysRun(rc, text or out, dt, out)
    if check and rc != 0:
        tail = "\n".join((text or out).strip().splitlines()[-25:])
        raise YosysError(f"yosys failed (exit {rc}) running {os.path.join(cwd, ys)}:\n{tail}", text or out)
    return run


_VERSION = None


def version() -> str:
    """e.g. 'Yosys 0.69 (git sha1 9f75ca1f9, ...)'."""
    global _VERSION
    if _VERSION is None:
        proc = subprocess.run([sys.executable, "-c", _RUNNER, "-V"], env=_env(), capture_output=True, text=True)
        lines = [ln for ln in (proc.stdout or "").splitlines() if ln.startswith("Yosys")]
        _VERSION = lines[0].strip() if lines else "unknown"
    return _VERSION


def short_version() -> str:
    m = re.match(r"(Yosys \S+ \(git sha1 [0-9a-f]+)", version())
    return (m.group(1) + ")") if m else version()


def package_versions() -> dict:
    from importlib import metadata
    out = {}
    for pkg in ("yowasp-yosys", "yowasp-runtime", "wasmtime", "z3-solver"):
        try:
            out[pkg] = metadata.version(pkg)
        except metadata.PackageNotFoundError:
            out[pkg] = None
    return out
