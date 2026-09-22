#!/usr/bin/env python3
"""Package the tested runtime archive for content-addressed PR publication."""
import argparse, hashlib, io, json, os, tarfile
from pathlib import Path

from runtime_common import input_fingerprint, runtime_members, safe_extract, validate_tree

ROOT = Path(__file__).resolve().parents[1]
def prepare(source: Path, output: Path):
    output.mkdir(parents=True, exist_ok=False)
    archives = list(source.glob("roc-runtime-*.tar.gz"))
    if len(archives) != 1:
        raise ValueError("expected exactly one tested runtime archive")
    fingerprint = input_fingerprint()
    asset = output / "link-inputs-all.tar"
    stage = output / ".stage"
    safe_extract(archives[0], stage, expected=runtime_members())
    validate_tree(stage)
    with tarfile.open(asset, "w", format=tarfile.USTAR_FORMAT) as archive:
        for name in sorted(runtime_members()):
            data = (stage / name).read_bytes()
            member = tarfile.TarInfo(name)
            member.size, member.mode, member.mtime = len(data), 0o644, 0
            archive.addfile(member, io.BytesIO(data))
    for path in sorted(stage.rglob("*"), reverse=True):
        path.rmdir() if path.is_dir() else path.unlink()
    stage.rmdir()
    identity = {"repository": os.environ["GITHUB_REPOSITORY"], "sha": os.environ["GITHUB_SHA"],
                "ref": os.environ["GITHUB_REF"],
                "workflow": os.environ["GITHUB_REPOSITORY"] + "/.github/workflows/runtime.yml",
                "input_fingerprint": fingerprint}
    manifest = {"schema_version": 1, "kind": "roc-zig-link-inputs", "source": identity,
                "assets": {"all": {"asset": asset.name,
                "sha256": hashlib.sha256(asset.read_bytes()).hexdigest(), "size": asset.stat().st_size}}}
    (output / "build-input-release.json").write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.source, args.output)
