#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

work_dir="${1:-.zig-cache/local-examples}"
examples_out="$work_dir/examples"

rm -rf "$work_dir"
mkdir -p "$examples_out"

python3 - "$examples_out" <<'PY'
from pathlib import Path
import os
import re
import sys

examples_out = Path(sys.argv[1])
source_dir = Path("examples")
platform_path = Path("platform/main.roc").resolve()
replacement_path = os.path.relpath(platform_path, examples_out.resolve())
replacement = f'platform "{Path(replacement_path).as_posix()}"'

platform_pattern = re.compile(
    r'platform "(?:'
    r'https://github\.com/lukewilliamboswell/roc-platform-template-zig/releases/download/[^"]+'
    r'|\.\./platform/main\.roc'
    r')"'
)

rewritten = 0
for source in sorted(source_dir.glob("*.roc")):
    text = source.read_text(encoding="utf-8")
    updated, count = platform_pattern.subn(replacement, text, count=1)
    if count != 1:
        raise SystemExit(f"example does not use a recognized platform URL: {source}")
    (examples_out / source.name).write_text(updated, encoding="utf-8")
    rewritten += 1

if rewritten == 0:
    raise SystemExit("no examples found to rewrite")
PY
