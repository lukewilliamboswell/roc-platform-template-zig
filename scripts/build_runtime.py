#!/usr/bin/env python3
"""Build the independently versioned runtime from a verified Zig distribution."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

from runtime_common import ROOT, RUNTIME_FILES, digest, safe_extract, write_json, validate_tree

SOURCES = ROOT / "runtime/sources.json"


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def toolchain(work: Path, lock: dict) -> Path:
    machine = {"x86_64": "x86_64", "aarch64": "aarch64"}.get(platform.machine())
    if platform.system() != "Linux" or machine is None:
        raise ValueError("The runtime producer requires x86-64 or ARM64 Linux")
    source = lock["toolchains"][f"{machine}-linux"]
    archive = work / "zig.tar.xz"
    urllib.request.urlretrieve(source["url"], archive)
    if digest(archive) != source["sha256"]:
        raise ValueError("Zig distribution checksum mismatch")
    signature = work / "zig.minisig"
    urllib.request.urlretrieve(source["url"] + ".minisig", signature)
    run(["minisign", "-Vm", archive, "-x", signature, "-P", lock["zig_minisign_key"]])
    installed = work / "toolchain"
    safe_extract(archive, installed)
    executables = list(installed.glob("*/zig"))
    if len(executables) != 1:
        raise ValueError("Unexpected Zig distribution layout")
    zig = executables[0]
    if subprocess.check_output([zig, "version"], text=True).strip() != lock["zig_version"]:
        raise ValueError("Zig executable version mismatch")
    return zig


def link_inputs(log: str, cache: Path) -> dict[str, Path]:
    lines = [line for line in log.splitlines() if line.startswith("ld.lld ") and " -r " not in line]
    if len(lines) != 1:
        raise ValueError("Expected exactly one Zig linker invocation:\n" + log)
    result = {}
    for token in shlex.split(lines[0])[1:]:
        path = Path(token)
        if not path.is_absolute():
            path = cache.parent / path
        if path.name in RUNTIME_FILES:
            if path.name in result or not path.resolve().is_relative_to(cache.resolve()) or not path.is_file():
                raise ValueError(f"Unexpected runtime linker input: {token}")
            result[path.name] = path
        elif token.endswith(".a"):
            raise ValueError(f"Unexpected linker library: {token}")
    if set(result) != set(RUNTIME_FILES):
        raise ValueError(f"Incomplete Zig runtime inputs: {result.keys()}")
    return result


def normalize_archive(zig: Path, source: Path, destination: Path, work: Path):
    """Zig's archives contain cache paths; rebuild with stable member names."""
    members = subprocess.check_output([zig, "ar", "t", source], text=True).splitlines()
    objects = []
    for index, member in enumerate(members):
        # Inputs are compiler output in our isolated cache, never downloaded code.
        obj = work / f"{index:04d}.o"
        obj.write_bytes(subprocess.check_output([zig, "ar", "pP", source, member]))
        stripped = work / f"stripped-{index:04d}.o"
        run(["llvm-objcopy-18", "--strip-debug", obj, stripped])
        objects.append(stripped)
    run([zig, "ar", "rcsD", destination, *objects])


def sbom(stage: Path, manifest: dict, archive: Path, epoch: int) -> dict:
    version = manifest["version"]
    packages = []
    for ident, name, ver, license_name in [
        ("runtime", "roc-platform-linux-runtime", version, "NOASSERTION"),
        ("musl", "musl (Zig distribution)", manifest["sources"]["musl_version"], "NOASSERTION"),
        ("zig-libc", "Zig libc", manifest["sources"]["zig_version"], "MIT"),
        ("compiler-rt", "Zig compiler runtime", manifest["sources"]["zig_version"], "MIT"),
        ("zig", "Zig compiler distribution", manifest["sources"]["zig_version"], "NOASSERTION"),
    ]:
        packages.append({"SPDXID": f"SPDXRef-{ident}", "name": name, "versionInfo": ver,
                         "downloadLocation": "https://ziglang.org/download/0.16.0/" if ident != "runtime" else "NOASSERTION",
                         "filesAnalyzed": False, "licenseConcluded": "NOASSERTION", "licenseDeclared": license_name,
                         "copyrightText": "NOASSERTION"})
    compiler = manifest["sources"]["toolchains"][manifest["builder_platform"]]
    packages[-1]["downloadLocation"] = compiler["url"]
    packages[-1]["checksums"] = [{"algorithm": "SHA256", "checksumValue": compiler["sha256"]}]
    packages.append({"SPDXID": "SPDXRef-objcopy", "name": "LLVM objcopy",
                     "versionInfo": manifest["sources"]["objcopy"]["version"],
                     "downloadLocation": manifest["sources"]["objcopy"]["source"],
                     "filesAnalyzed": False, "licenseConcluded": "NOASSERTION",
                     "licenseDeclared": "Apache-2.0 WITH LLVM-exception", "copyrightText": "NOASSERTION"})
    packages[0]["checksums"] = [{"algorithm": "SHA256", "checksumValue": digest(archive)}]
    files, relationships = [], [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-runtime"}]
    for ident in ("musl", "zig-libc", "compiler-rt"):
        relationships.append({"spdxElementId": "SPDXRef-runtime", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": f"SPDXRef-{ident}"})
    relationships.append({"spdxElementId": "SPDXRef-zig", "relationshipType": "BUILD_TOOL_OF", "relatedSpdxElement": "SPDXRef-runtime"})
    inventory = {**manifest["files"], "manifest.json": digest(stage / "manifest.json")}
    relationships.append({"spdxElementId": "SPDXRef-objcopy", "relationshipType": "BUILD_TOOL_OF", "relatedSpdxElement": "SPDXRef-runtime"})
    for index, (name, sha) in enumerate(sorted(inventory.items())):
        ident = f"SPDXRef-file-{index}"
        files.append({"SPDXID": ident, "fileName": "./" + name,
                      "checksums": [{"algorithm": "SHA256", "checksumValue": sha}],
                      "licenseConcluded": "NOASSERTION", "licenseInfoInFiles": ["NOASSERTION"], "copyrightText": "NOASSERTION"})
        relationships.append({"spdxElementId": "SPDXRef-runtime", "relationshipType": "CONTAINS", "relatedSpdxElement": ident})
    return {"spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
            "name": f"roc-platform-runtime-{version}",
            "documentNamespace": f"https://spdx.org/spdxdocs/roc-runtime-{digest(archive)}",
            "creationInfo": {"created": datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "creators": ["Tool: roc-platform-template-zig-runtime-builder"]},
            "packages": packages, "files": files, "relationships": relationships}


def build(output: Path):
    lock = json.loads(SOURCES.read_text())
    version = subprocess.check_output([lock["objcopy"]["command"], "--version"], text=True)
    if lock["objcopy"]["version"] not in version:
        raise ValueError("Unexpected llvm-objcopy version")
    output.mkdir(parents=True, exist_ok=False)
    cache_root = ROOT / ".zig-cache"
    cache_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="runtime-build-", dir=cache_root) as tmp:
        work = Path(tmp)
        zig = toolchain(work, lock)
        cache = work / "cache"
        env = {**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(cache), "ZIG_LOCAL_CACHE_DIR": str(work / "local")}
        stage = work / "stage"
        commands = {}
        for name, target in lock["targets"].items():
            target_out = stage / "targets" / name
            target_out.mkdir(parents=True)
            # stdin has stable contents and no absolute source path. -g0 avoids debug paths.
            flags = ["cc", "-target", target, "-mcpu=" + lock["cpu"], "-static", lock["optimization"], "-g0"]
            result = run([zig, *flags, "-x", "c", "-", "-o", work / f"probe-{name}", "-v"],
                         input="int main(void) { return 0; }\n", text=True, capture_output=True, env=env, cwd=work)
            commands[name] = ["zig", *flags, "-x", "c", "-", "-o", "probe", "-v"]
            for filename, source in link_inputs(result.stderr, cache).items():
                if filename.endswith(".a"):
                    objects = work / f"objects-{name}-{filename}"
                    objects.mkdir()
                    normalize_archive(zig, source, target_out / filename, objects)
                else:
                    run(["llvm-objcopy-18", "--strip-debug", source, target_out / filename])
        (stage / "licenses").mkdir()
        shutil.copyfile(zig.parent / "LICENSE", stage / "licenses/Zig.txt")
        shutil.copyfile(zig.parent / "lib/libc/musl/COPYRIGHT", stage / "licenses/musl.txt")
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        epoch = int(subprocess.check_output(["git", "show", "-s", "--format=%ct", "HEAD"], cwd=ROOT))
        manifest = {"schema": 1, "version": lock["runtime_version"], "source_commit": sha,
                    "sources": lock, "commands": commands, "builder_platform": platform.machine() + "-linux",
                    "files": {p.relative_to(stage).as_posix(): digest(p) for p in sorted(stage.rglob("*")) if p.is_file()}}
        write_json(stage / "manifest.json", manifest)
        validate_tree(stage)
        archive = output / f"roc-runtime-{lock['runtime_version']}.tar.gz"
        with archive.open("wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for path in sorted(stage.rglob("*")):
                    if path.is_file():
                        info = tarfile.TarInfo(path.relative_to(stage).as_posix())
                        info.size, info.mode, info.mtime = path.stat().st_size, 0o644, 0
                        with path.open("rb") as stream:
                            tar.addfile(info, stream)
        write_json(output / "runtime.spdx.json", sbom(stage, manifest, archive, epoch))
        (output / "SHA256SUMS").write_text("".join(f"{digest(p)}  {p.name}\n" for p in sorted(output.iterdir()) if p.is_file()))
        print(f"Built {archive}: {digest(archive)}", flush=True)


def smoke(archive: Path):
    lock = json.loads(SOURCES.read_text())
    with tempfile.TemporaryDirectory(prefix="runtime-smoke-", dir=ROOT / ".zig-cache") as tmp:
        work = Path(tmp)
        zig = toolchain(work, lock)
        stage = work / "runtime"
        from runtime_common import runtime_members
        safe_extract(archive, stage, expected=runtime_members())
        validate_tree(stage)
        name = {"x86_64": "x64musl", "aarch64": "arm64musl"}[platform.machine()]
        target = lock["targets"][name]
        obj, binary = work / "smoke.o", work / "smoke"
        run([zig, "cc", "-target", target, "-mcpu=baseline", "-O2", "-c", ROOT / "runtime/smoke.c", "-o", obj])
        libs = stage / "targets" / name
        # Direct LLD invocation ensures there is no implicit host/toolchain libc.
        run([zig, "ld.lld", "-static", "-o", binary, libs / "crt1.o", obj,
             "--start-group", *(libs / f for f in RUNTIME_FILES[1:]), "--end-group"])
        run([binary])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build").add_argument("--output", type=Path, required=True)
    sub.add_parser("smoke").add_argument("archive", type=Path)
    args = parser.parse_args()
    if args.command == "build":
        build(args.output.resolve())
    else:
        (ROOT / ".zig-cache").mkdir(exist_ok=True)
        smoke(args.archive.resolve())
