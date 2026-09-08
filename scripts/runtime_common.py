"""Archive and inventory primitives shared by runtime producer and consumer."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_FILES = ("crt1.o", "libc.a", "libzigc.a", "libcompiler_rt.a")
TARGETS = ("x64musl", "arm64musl")
LICENSES = ("licenses/Zig.txt", "licenses/musl.txt")


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
        return value.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def safe_extract(archive: Path, destination: Path, *, expected: set[str] | None = None) -> None:
    """Accept regular files/directories only, never links or ambiguous paths."""
    with tarfile.open(archive) as tar:
        seen: set[str] = set()
        members = tar.getmembers()
        total = 0
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or "\\" in member.name
                    or ":" in member.name or not path.parts or member.name in seen
                    or path.as_posix() != member.name.rstrip("/")
                    or not (member.isfile() or member.isdir())):
                raise ValueError(f"Unsafe archive member: {member.name}")
            seen.add(member.name)
            if expected is not None and (not member.isfile() or member.name not in expected):
                raise ValueError(f"Unexpected archive member: {member.name}")
            total += member.size
            if total > 2_000_000_000:
                raise ValueError("Archive exceeds extraction size limit")
        if expected is not None and seen != expected:
            raise ValueError(f"Incomplete runtime archive: {expected - seen}")
        # Paths and types were checked above; use explicit writes for Python 3.10+.
        for member in members:
            path = destination / member.name
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, path.open("wb") as output:
                    import shutil
                    shutil.copyfileobj(source, output)
                path.chmod(member.mode & 0o777)


def runtime_members() -> set[str]:
    return {f"targets/{target}/{name}" for target in TARGETS for name in RUNTIME_FILES} | set(LICENSES) | {"manifest.json"}


def validate_tree(directory: Path) -> dict:
    manifest = json.loads((directory / "manifest.json").read_text())
    expected = runtime_members() - {"manifest.json"}
    if manifest.get("schema") != 1 or set(manifest.get("files", {})) != expected:
        raise ValueError("Invalid runtime inventory")
    actual = {p.relative_to(directory).as_posix() for p in directory.rglob("*") if p.is_file()}
    if actual != runtime_members() or any(p.is_symlink() for p in directory.rglob("*")):
        raise ValueError("Unexpected runtime contents")
    for name, checksum in manifest["files"].items():
        if digest(directory / name) != checksum:
            raise ValueError(f"Runtime file hash mismatch: {name}")
    return manifest
