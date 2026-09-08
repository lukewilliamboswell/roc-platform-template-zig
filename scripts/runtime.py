#!/usr/bin/env python3
"""Fetch and verify the locked runtime once; check/stage it offline thereafter."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

from runtime_common import ROOT, RUNTIME_FILES, digest, runtime_members, safe_extract, validate_tree

LOCK = ROOT / "runtime/dependency.json"
SPDX = "https://spdx.dev/Document/v2.3"
PROVENANCE = "https://slsa.dev/provenance/v1"


def load_lock() -> dict:
    if not LOCK.is_file():
        raise ValueError("No runtime release has been pinned yet")
    lock = json.loads(LOCK.read_text())
    if (lock.get("schema") != 1 or not re.fullmatch(r"[0-9a-f]{64}", lock.get("sha256", ""))
            or not re.fullmatch(r"[0-9a-f]{64}", lock.get("sbom_sha256", ""))
            or not re.fullmatch(r"[0-9a-f]{40}", lock.get("source_commit", ""))
            or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", lock.get("repository", ""))
            or not re.fullmatch(r"runtime-[0-9]+\.[0-9]+\.[0-9]+", lock.get("tag", ""))
            or lock.get("workflow") != ".github/workflows/runtime.yml"
            or lock.get("source_ref") != "refs/heads/main"):
        raise ValueError("Invalid runtime dependency lock")
    expected = f"https://github.com/{lock['repository']}/releases/download/{lock['tag']}/"
    if lock.get("url") != expected + f"roc-runtime-{lock['tag'][8:]}.tar.gz":
        raise ValueError("Runtime URL must identify the locked release")
    return lock


def cache_path(lock: dict) -> Path:
    return ROOT / ".zig-cache/runtime" / lock["sha256"]


def verification_args(archive: Path, bundle: Path, lock: dict, predicate: str) -> list[str]:
    return ["gh", "attestation", "verify", str(archive), "--bundle", str(bundle),
            "--repo", lock["repository"], "--signer-workflow", lock["repository"] + "/" + lock["workflow"],
            "--source-digest", lock["source_commit"], "--signer-digest", lock["source_commit"],
            "--source-ref", lock["source_ref"], "--deny-self-hosted-runners", "--predicate-type", predicate,
            "--format", "json"]


def verify_attestations(directory: Path, lock: dict):
    for filename, predicate in [("provenance.sigstore.json", PROVENANCE), ("sbom.sigstore.json", SPDX)]:
        output = subprocess.check_output(verification_args(directory / "archive.tar.gz", directory / filename, lock, predicate), text=True)
        result = json.loads(output)
        if not result:
            raise ValueError("No valid attestations returned")
        if predicate == SPDX:
            sbom = json.loads((directory / "runtime.spdx.json").read_text())
            if not any(entry["verificationResult"]["statement"]["predicate"] == sbom for entry in result):
                raise ValueError("Downloaded SBOM differs from the signed SBOM")


def check(lock: dict | None = None) -> tuple[Path, dict]:
    lock = load_lock() if lock is None else lock
    directory = cache_path(lock)
    archive = directory / "archive.tar.gz"
    if not archive.is_file():
        raise ValueError("Runtime is missing. Run: python3 scripts/runtime.py fetch")
    if digest(archive) != lock["sha256"]:
        raise ValueError("Cached runtime archive checksum mismatch; run runtime.py fetch to repair")
    if digest(directory / "runtime.spdx.json") != lock["sbom_sha256"]:
        raise ValueError("Cached runtime SBOM checksum mismatch")
    # Bind the on-disk manifest to the locked archive, not an editable receipt.
    with tarfile.open(archive) as tar:
        original = tar.extractfile("manifest.json").read()
    tree = directory / "tree"
    if (tree / "manifest.json").read_bytes() != original:
        raise ValueError("Cached manifest differs from the locked archive")
    manifest = validate_tree(tree)
    if manifest["source_commit"] != lock["source_commit"] or "runtime-" + manifest["version"] != lock["tag"]:
        raise ValueError("Runtime inventory does not match the dependency lock")
    return tree, manifest


def fetch():
    lock = load_lock()
    destination = cache_path(lock)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="download-", dir=destination.parent) as tmp:
        directory = Path(tmp)
        base = lock["url"].rsplit("/", 1)[0]
        for name, url in [("archive.tar.gz", lock["url"]),
                          *((name, base + "/" + name) for name in ("runtime.spdx.json", "provenance.sigstore.json", "sbom.sigstore.json"))]:
            print(f"Downloading {url}", flush=True)
            urllib.request.urlretrieve(url, directory / name)
        if digest(directory / "archive.tar.gz") != lock["sha256"]:
            raise ValueError("Downloaded runtime checksum mismatch")
        if digest(directory / "runtime.spdx.json") != lock["sbom_sha256"]:
            raise ValueError("Downloaded runtime SBOM checksum mismatch")
        verify_attestations(directory, lock)
        tree = directory / "tree"
        safe_extract(directory / "archive.tar.gz", tree, expected=runtime_members())
        manifest = validate_tree(tree)
        if manifest["source_commit"] != lock["source_commit"] or "runtime-" + manifest["version"] != lock["tag"]:
            raise ValueError("Downloaded runtime inventory does not match the lock")
        # Move a complete verified directory into place; retain the old one until then.
        backup = directory.parent / (lock["sha256"] + ".previous")
        if backup.exists():
            raise ValueError("Interrupted runtime installation found; inspect " + str(backup))
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
    print("Verified runtime installed. Builds now work offline.")


def stage():
    tree, manifest = check()
    for target in ("x64musl", "x64v1musl", "arm64musl", "arm64v1musl"):
        destination = ROOT / "platform/targets" / target
        destination.mkdir(parents=True, exist_ok=True)
        for filename in RUNTIME_FILES:
            source = tree / "targets" / target.replace("v1", "") / filename
            # Atomic per-file replacement avoids consumers observing partial copies.
            with tempfile.NamedTemporaryFile(dir=destination, delete=False) as output:
                temporary = Path(output.name)
                output.write(source.read_bytes())
            try:
                os.replace(temporary, destination / filename)
            finally:
                temporary.unlink(missing_ok=True)
    return tree, manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "check", "stage"))
    args = parser.parse_args()
    try:
        if args.command == "fetch":
            fetch()
        elif args.command == "check":
            check()
            print("Runtime files match the locked archive")
        else:
            stage()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
