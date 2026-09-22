#!/usr/bin/env python3
"""Repackage the tested aggregate linker inputs for the trusted PR publisher."""
import argparse, hashlib, io, json, os, re, subprocess, tarfile
from pathlib import Path

from linker_inputs_common import ROOT, read_archive

INPUTS = ("linker-inputs/sources.json", "linker-inputs/macos-interfaces/libSystem.json",
          "linker-inputs/macos-interfaces/PROVENANCE.md", "runtime/sources.json",
          "scripts/build_linker_inputs.py", "scripts/linker_inputs_common.py",
          "scripts/build_input_release.py", ".github/workflows/linker-inputs.yml")


def fingerprint():
    records = []
    for name in INPUTS:
        blob = subprocess.check_output(["git", "rev-parse", f"HEAD:{name}"], cwd=ROOT, text=True).strip()
        if not re.fullmatch(r"[0-9a-f]{40}", blob):
            raise ValueError("uncommitted producer input: " + name)
        records.append(f"{name}\0{blob}\n")
    return hashlib.sha256("".join(records).encode()).hexdigest()


def prepare(source, output):
    archives = list(Path(source).glob("roc-zig-linker-inputs-*.tar.gz"))
    if len(archives) != 1:
        raise ValueError("expected one tested aggregate archive")
    manifest, files = read_archive(archives[0])
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    asset = output / "link-inputs-all.tar"
    with tarfile.open(asset, "w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data in sorted(files.items()):
            member = tarfile.TarInfo(name)
            member.size, member.mode, member.mtime = len(data), 0o644, 0
            archive.addfile(member, io.BytesIO(data))
    release = {"schema_version": 1, "kind": "roc-zig-link-inputs",
               "source": {"repository": os.environ["GITHUB_REPOSITORY"], "sha": os.environ["GITHUB_SHA"],
                          "ref": os.environ["GITHUB_REF"],
                          "workflow": os.environ["GITHUB_REPOSITORY"] + "/.github/workflows/linker-inputs.yml",
                          "input_fingerprint": fingerprint()},
               "assets": {"all": {"asset": asset.name,
                          "sha256": hashlib.sha256(asset.read_bytes()).hexdigest(), "size": asset.stat().st_size}}}
    (output / "build-input-release.json").write_text(json.dumps(release, sort_keys=True, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.source, args.output)
