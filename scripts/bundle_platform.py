#!/usr/bin/env python3
"""Bundle an explicit inventory from clean staging; never glob local binaries."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from runtime import load_lock, stage
from runtime_common import ROOT, RUNTIME_FILES, digest, write_json

TARGETS = ("x64mac", "arm64mac", "x64win", "arm64win", "x64musl", "x64v1musl", "arm64musl", "arm64v1musl")


def bundle(arguments):
    runtime, manifest = stage()
    with tempfile.TemporaryDirectory(prefix="platform-bundle-", dir=ROOT / ".zig-cache") as tmp:
        staging = Path(tmp)
        sources = {p.name: p for p in (ROOT / "platform").glob("*.roc")}
        for target in TARGETS:
            host = "host.lib" if target.endswith("win") else "libhost.a"
            for name in (host, *(RUNTIME_FILES if target.endswith("musl") else ())):
                relative = f"targets/{target}/{name}"
                sources[relative] = ROOT / "platform" / relative
        for name in ("Zig.txt", "musl.txt"):
            sources["licenses/" + name] = runtime / "licenses" / name
        sources["licenses/platform.txt"] = ROOT / "LICENSE"
        sources["runtime-manifest.json"] = runtime / "manifest.json"
        for relative, source in sources.items():
            if not source.is_file() or source.is_symlink():
                raise ValueError(f"Missing or invalid bundle input: {source}; run zig build first")
            destination = staging / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        files = sorted(sources)
        result = subprocess.run(["roc", "bundle", *files, "--output-dir", str(ROOT), *arguments], cwd=staging,
                                check=True, text=True, capture_output=True)
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        matches = re.findall(r"^Created:\s+(.+\.tar\.zst)$", result.stdout + result.stderr, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError("Expected exactly one created platform archive")
        archive = Path(matches[0]).resolve()
        if archive.parent != ROOT or not archive.is_file():
            raise ValueError("Unexpected platform archive path")
        write_json(ROOT / ".zig-cache/platform-bundle.json", {
            "archive": archive.name, "sha256": digest(archive), "runtime": load_lock(),
            "files": {name: digest(staging / name) for name in files},
        })


if __name__ == "__main__":
    bundle(sys.argv[1:])
