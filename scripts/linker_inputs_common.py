"""Strict inventory and deterministic archive primitives for linker inputs."""
from __future__ import annotations

import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import tarfile

# Git Bash can expose the checked-out script through an MSYS path while the
# native Windows Python process receives a Windows workspace path. Prefer the
# runner's explicit workspace so all platforms locate the committed lock.
ROOT = (Path(os.environ["GITHUB_WORKSPACE"]) if "GITHUB_WORKSPACE" in os.environ
        else Path(__file__).resolve().parents[1])
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
SHA256 = re.compile(r"[0-9a-f]{64}")
COMMIT = re.compile(r"[0-9a-f]{40}")
MAX_ARCHIVE = 256 * 1024 * 1024
MAX_UNPACKED = 512 * 1024 * 1024


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return (bool(name) and not path.is_absolute() and path.as_posix() == name
            and "\\" not in name and ":" not in name
            and all(part not in ("", ".", "..") for part in path.parts))


def write_archive(path: Path, files: dict[str, bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for name, data in sorted(files.items()):
                if not safe_name(name):
                    raise ValueError(f"Unsafe linker-input path: {name}")
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = len(data), 0o644, 0
                tar.addfile(info, io.BytesIO(data))


def read_archive(path: Path) -> tuple[dict, dict[str, bytes]]:
    if path.stat().st_size > MAX_ARCHIVE:
        raise ValueError("Linker-input archive exceeds size limit")
    files: dict[str, bytes] = {}
    total = 0
    with tarfile.open(path, "r:*") as tar:
        for member in tar:
            if not member.isfile() or not safe_name(member.name) or member.name in files:
                raise ValueError(f"Unsafe or duplicate archive entry: {member.name}")
            total += member.size
            if total > MAX_UNPACKED:
                raise ValueError("Linker-input archive exceeds unpacked size limit")
            source = tar.extractfile(member)
            if source is None:
                raise ValueError(f"Missing archive data: {member.name}")
            files[member.name] = source.read()
    if "dependency.json" not in files:
        raise ValueError("Linker-input archive has no dependency.json")
    manifest = json.loads(files["dependency.json"])
    payload = set(files) - {"dependency.json"}
    if (manifest.get("schema") != 1 or VERSION.fullmatch(manifest.get("version", "")) is None
            or COMMIT.fullmatch(manifest.get("source_commit", "")) is None
            or SHA256.fullmatch(manifest.get("input_fingerprint", "")) is None
            or set(manifest.get("files", {})) != payload):
        raise ValueError("Invalid linker-input dependency manifest")
    for name in payload:
        record = manifest["files"][name]
        if set(record) != {"sha256", "size"} or record["size"] != len(files[name]) \
                or record["sha256"] != digest_bytes(files[name]):
            raise ValueError(f"Linker-input integrity failure: {name}")
    return manifest, files
