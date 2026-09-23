#!/usr/bin/env python3
"""Fetch a signed linker-input release once; check and stage it offline."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request

from linker_inputs_common import ROOT, COMMIT, SHA256, digest, read_archive

LOCK = ROOT / "linker-inputs.lock.json"
if not LOCK.is_file() and (Path.cwd() / "link-inputs.lock.json").is_file():
    ROOT = Path.cwd()
    LOCK = ROOT / "link-inputs.lock.json"
PROVENANCE = "https://slsa.dev/provenance/v1"


def load_lock() -> dict:
    if not LOCK.is_file():
        raise ValueError("No aggregate linker-input release is pinned yet; see linker-inputs/README.md")
    lock = json.loads(LOCK.read_text())
    record, source = lock.get("targets", {}).get("all", {}), lock.get("source", {})
    if (set(lock) != {"schema_version", "kind", "repository", "release", "manifest", "source", "targets"}
                or lock.get("kind") != "roc-zig-link-inputs"
                or lock.get("repository") != "lukewilliamboswell/roc-platform-template-zig"
                or not re.fullmatch(r"link-inputs-sha256-[0-9a-f]{64}", lock.get("release", ""))
                or set(lock.get("targets", {})) != {"all"}
                or set(record) != {"asset", "sha256", "size"} or record.get("asset") != "link-inputs-all.tar"
                or SHA256.fullmatch(record.get("sha256", "")) is None
                or not isinstance(record.get("size"), int) or record["size"] <= 0
                or source.get("repository") != lock["repository"]
                or source.get("workflow") != lock["repository"] + "/.github/workflows/linker-inputs.yml"
                or COMMIT.fullmatch(source.get("sha", "")) is None
                or SHA256.fullmatch(source.get("input_fingerprint", "")) is None):
        raise ValueError("Invalid content-addressed linker-input lock")
    return {"content": True, "repository": lock["repository"], "tag": lock["release"],
            "url": f"https://github.com/{lock['repository']}/releases/download/{lock['release']}/{record['asset']}",
            "sha256": record["sha256"], "size": record["size"], "source_commit": source["sha"],
            "input_fingerprint": source["input_fingerprint"]}


def cache_path(lock: dict) -> Path:
    return ROOT / ".zig-cache/linker-inputs" / lock["sha256"]


def attest_args(subject: Path, lock: dict) -> list[str]:
    return ["gh", "attestation", "verify", str(subject),
            "--repo", lock["repository"],
            "--signer-workflow", lock["workflow"],
            "--source-digest", lock["source_commit"], "--signer-digest", lock["signer_commit"],
            "--source-ref", lock["source_ref"], "--deny-self-hosted-runners",
            "--predicate-type", PROVENANCE, "--format", "json"]


def check(lock: dict | None = None) -> tuple[Path, dict]:
    lock = load_lock() if lock is None else lock
    directory = cache_path(lock)
    archive = directory / "archive.tar.gz"
    if not archive.is_file():
        raise ValueError("Linker inputs are missing. Run: python3 scripts/linker_inputs.py fetch")
    if archive.stat().st_size != lock["size"] or digest(archive) != lock["sha256"]:
        raise ValueError("Cached linker-input archive does not match the lock")
    if not lock.get("content") and digest(directory / "linker-inputs.spdx.json") != lock["sbom_sha256"]:
        raise ValueError("Cached linker-input SBOM does not match the lock")
    manifest, files = read_archive(archive)
    if (manifest["source_commit"] != lock["source_commit"]
            or (not lock.get("content") and "linker-inputs-v" + manifest["version"] != lock["tag"])):
        raise ValueError("Archive dependency metadata does not match the lock")
    tree = directory / "tree"
    actual = {path.relative_to(tree).as_posix() for path in tree.rglob("*") if path.is_file()}
    if actual != set(files) or any(path.is_symlink() for path in tree.rglob("*")):
        raise ValueError("Unexpected staged linker-input inventory")
    for name, data in files.items():
        if (tree / name).read_bytes() != data:
            raise ValueError(f"Staged linker input differs from archive: {name}")
    return tree, manifest


def fetch() -> None:
    lock = load_lock()
    destination = cache_path(lock)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        try:
            check(lock)
        except (ValueError, OSError, json.JSONDecodeError):
            pass
        else:
            print("Reused content-hashed linker inputs from the verified cache")
            return
    with tempfile.TemporaryDirectory(prefix="linker-input-download-", dir=destination.parent) as temporary:
        directory = Path(temporary)
        urllib.request.urlretrieve(lock["url"], directory / "archive.tar.gz")
        if not lock.get("content"):
            base = lock["url"].rsplit("/", 1)[0]
            urllib.request.urlretrieve(base + "/linker-inputs.spdx.json", directory / "linker-inputs.spdx.json")
        if (digest(directory / "archive.tar.gz") != lock["sha256"]
                or (not lock.get("content") and digest(directory / "linker-inputs.spdx.json") != lock["sbom_sha256"])):
            raise ValueError("Downloaded linker inputs do not match the lock")
        if not lock.get("content"):
            for subject in (directory / "archive.tar.gz", directory / "linker-inputs.spdx.json"):
                result = json.loads(subprocess.check_output(attest_args(subject, lock), text=True))
                if not result:
                    raise ValueError("No valid linker-input attestation returned")
        manifest, files = read_archive(directory / "archive.tar.gz")
        tree = directory / "tree"
        for name, data in files.items():
            path = tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        if manifest["source_commit"] != lock["source_commit"]:
            raise ValueError("Downloaded dependency metadata does not match the lock")
        backup = destination.with_name(destination.name + ".previous")
        if backup.exists():
            raise ValueError("Interrupted linker-input installation found: " + str(backup))
        if destination.exists():
            destination.rename(backup)
        try:
            directory.rename(destination)
        except BaseException:
            if backup.exists():
                backup.rename(destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    check(lock)


def stage() -> tuple[Path, dict]:
    tree, manifest = check()
    mappings = {
        "x64musl": "x64musl", "x64v1musl": "x64musl",
        "arm64musl": "arm64musl", "arm64v1musl": "arm64musl",
        "x64mac": "x64mac", "arm64mac": "arm64mac", "x64win": "x64win",
    }
    for destination_name, source_name in mappings.items():
        source = tree / "targets" / source_name
        destination = ROOT / "platform/targets" / destination_name
        destination.mkdir(parents=True, exist_ok=True)
        for item in source.iterdir():
            if not item.is_file() or item.is_symlink():
                raise ValueError("Invalid linker-input staging source: " + str(item))
            with tempfile.NamedTemporaryFile(dir=destination, delete=False) as output:
                temporary = Path(output.name)
                output.write(item.read_bytes())
            try:
                os.replace(temporary, destination / item.name)
            finally:
                temporary.unlink(missing_ok=True)
    return tree, manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "check", "stage"))
    command = parser.parse_args().command
    try:
        if command == "fetch":
            fetch()
            print("Verified linker inputs installed; builds now work offline")
        elif command == "check":
            check()
            print("Linker inputs match the signed lock")
        else:
            stage()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
