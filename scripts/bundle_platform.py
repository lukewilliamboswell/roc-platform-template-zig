#!/usr/bin/env python3
"""Bundle an explicit inventory from clean staging; never glob local binaries."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from linker_inputs import load_lock, stage
from linker_inputs_common import ROOT, digest
from runtime_common import write_json

TARGETS = ("x64mac", "arm64mac", "x64win", "x64musl", "x64v1musl", "arm64musl", "arm64v1musl")


def bundle(arguments):
    inputs, manifest = stage()
    with tempfile.TemporaryDirectory(prefix="platform-bundle-", dir=ROOT / ".zig-cache") as tmp:
        staging = Path(tmp)
        sources = {p.name: p for p in (ROOT / "platform").glob("*.roc")}
        mappings = {"x64v1musl": "x64musl", "arm64v1musl": "arm64musl"}
        for target in TARGETS:
            host = "host.lib" if target.endswith("win") else "libhost.a"
            relative = f"targets/{target}/{host}"
            sources[relative] = ROOT / "platform" / relative
            source_target = mappings.get(target, target)
            for item in sorted((inputs / "targets" / source_target).iterdir()):
                relative = f"targets/{target}/{item.name}"
                sources[relative] = ROOT / "platform" / relative
        for directory in ("licenses", "sources"):
            for item in sorted((inputs / directory).iterdir()):
                sources[f"linker-inputs/{directory}/{item.name}"] = item
        sources["linker-inputs/dependency.json"] = inputs / "dependency.json"
        sources["licenses/platform.txt"] = ROOT / "LICENSE"
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
            "archive": archive.name, "sha256": digest(archive), "linker_inputs": load_lock(),
            "files": {name: digest(staging / name) for name in files},
        })


if __name__ == "__main__":
    bundle(sys.argv[1:])
