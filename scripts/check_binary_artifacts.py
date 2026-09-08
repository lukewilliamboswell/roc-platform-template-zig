#!/usr/bin/env python3
"""Reject compiled artifacts in the Git index, while allowing executable scripts."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
names = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
suffixes = {".o", ".obj", ".a", ".lib", ".dll", ".so", ".dylib", ".exe", ".wasm"}
magic = (b"\x7fELF", b"MZ", b"!<arch>\n", b"!<thin>\n", b"\0asm", b"\xfe\xed\xfa\xce",
         b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
bad = []
for name in filter(None, names):
    path = root / name
    if not path.is_file():
        continue
    with path.open("rb") as stream:
        header = stream.read(8)
    if path.suffix in suffixes or header.startswith(magic):
        bad.append(name)
if bad:
    raise SystemExit("Compiled artifacts must be built or fetched, not committed:\n" + "\n".join(bad))
print("No compiled artifacts tracked in Git")
