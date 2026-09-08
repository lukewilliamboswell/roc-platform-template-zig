#!/usr/bin/env python3
"""Exercise committed application headers with an isolated download cache."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
(root / ".zig-cache").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="roc-published-", dir=root / ".zig-cache") as cache:
    env = os.environ.copy()
    env["ROC_CACHE_DIR"] = cache
    env["XDG_CACHE_HOME"] = cache
    env["LOCALAPPDATA"] = cache
    subprocess.run(
        [sys.executable, "scripts/test.py", "--verbose"],
        cwd=root, env=env, check=True,
    )
