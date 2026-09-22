#!/usr/bin/env python3
"""Build the deterministic, independently released external linker inputs."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tarfile
import tempfile

from build_runtime import normalize_archive, toolchain
from linker_inputs_common import ROOT, digest, digest_bytes, json_bytes, read_archive, write_archive
from runtime_common import RUNTIME_FILES

SOURCES = ROOT / "linker-inputs/sources.json"
WINDOWS_IMPORTS = (
    "api-ms-win-crt-conio-l1-1-0.lib", "api-ms-win-crt-convert-l1-1-0.lib",
    "api-ms-win-crt-environment-l1-1-0.lib", "api-ms-win-crt-filesystem-l1-1-0.lib",
    "api-ms-win-crt-heap-l1-1-0.lib", "api-ms-win-crt-locale-l1-1-0.lib",
    "api-ms-win-crt-math-l1-1-0.lib", "api-ms-win-crt-multibyte-l1-1-0.lib",
    "api-ms-win-crt-private-l1-1-0.lib", "api-ms-win-crt-process-l1-1-0.lib",
    "api-ms-win-crt-runtime-l1-1-0.lib", "api-ms-win-crt-stdio-l1-1-0.lib",
    "api-ms-win-crt-string-l1-1-0.lib", "api-ms-win-crt-time-l1-1-0.lib",
    "api-ms-win-crt-utility-l1-1-0.lib", "advapi32.lib", "kernel32.lib", "ntdll.lib",
    "shell32.lib", "user32.lib",
)
WINDOWS_FILES = WINDOWS_IMPORTS


def run(args: list[object], **kwargs):
    return subprocess.run([str(value) for value in args], check=True, **kwargs)


def locate(trace: str, names: tuple[str, ...], work: Path) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for line in trace.splitlines():
        if not line.startswith("lld-link "):
            continue
        for token in shlex.split(line):
            normalized = token.replace("\\", "/")
            for name in names:
                if normalized.endswith("/" + name):
                    path = Path(token)
                    found[name] = path if path.is_absolute() else work / path
    if set(found) != set(names) or not all(path.is_file() for path in found.values()):
        raise ValueError("Incomplete Windows linker inputs: " + ", ".join(sorted(set(names) - set(found))))
    return found


def macos_stub() -> tuple[bytes, bytes, bytes]:
    catalog_path = ROOT / "linker-inputs/macos-interfaces/libSystem.json"
    provenance_path = ROOT / "linker-inputs/macos-interfaces/PROVENANCE.md"
    catalog = json.loads(catalog_path.read_text())
    required = {"schema", "library", "install_name", "targets", "symbols", "evidence"}
    if set(catalog) != required or catalog["schema"] != 1 or catalog["targets"] != ["x86_64-macos", "arm64-macos"]:
        raise ValueError("Invalid macOS interface catalog")
    if catalog["symbols"] != sorted(set(catalog["symbols"])):
        raise ValueError("macOS symbols must be unique and sorted")
    lines = ["--- !tapi-tbd", "tbd-version:     4", "targets:         [ x86_64-macos, arm64-macos ]",
             "install-name:    " + catalog["install_name"], "exports:",
             "  - targets:         [ x86_64-macos, arm64-macos ]", "    symbols:"]
    lines.extend("      - '" + symbol + "'" for symbol in catalog["symbols"])
    lines.append("...")
    return ("\n".join(lines) + "\n").encode(), catalog_path.read_bytes(), provenance_path.read_bytes()


def audit_macos_catalog(zig: Path, work: Path, nm: str) -> None:
    catalog = json.loads((ROOT / "linker-inputs/macos-interfaces/libSystem.json").read_text())
    unresolved: set[str] = set()
    for name, target in (("x64", "x86_64-macos"), ("arm64", "aarch64-macos")):
        archive = work / f"host-{name}.a"
        run([zig, "build-lib", ROOT / "src/host.zig", "-target", target, "-O", "ReleaseSafe",
             "-fcompiler-rt", "-femit-bin=" + str(archive)], cwd=ROOT)
        lines = subprocess.check_output([nm, "-g", archive], text=True).splitlines()
        undefined = {parts[1] for line in lines if len(parts := line.split()) == 2 and parts[0] == "U"}
        defined = {parts[-1] for line in lines if len(parts := line.split()) >= 3 and parts[-2] not in ("U", "u")}
        unresolved.update(undefined - defined)
    unresolved.discard("_roc_main")
    if unresolved != set(catalog["symbols"]):
        raise ValueError("macOS interface catalog differs from host audit; missing="
                         + repr(sorted(unresolved - set(catalog["symbols"]))) + ", extra="
                         + repr(sorted(set(catalog["symbols"]) - unresolved)))


def windows_files(zig: Path, work: Path) -> dict[str, bytes]:
    target_work = work / "windows"
    target_work.mkdir()
    cache = target_work / "cache"
    env = {**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(cache), "ZIG_LOCAL_CACHE_DIR": str(target_work / "local")}
    result = run([zig, "cc", "-target", "x86_64-windows-gnu", "-O2", "-g0", "-fno-sanitize=all",
                  "-x", "c", "-", "-o", target_work / "probe.exe", "-v"],
                 input="int main(void) { return 0; }\n", text=True, capture_output=True, env=env, cwd=work)
    found = locate(result.stderr, WINDOWS_FILES, work)
    output: dict[str, bytes] = {}
    for name, source in found.items():
        destination = target_work / ("normalized-" + name)
        shutil.copyfile(source, destination)
        output["targets/x64win/" + name] = destination.read_bytes()
    return output


def sbom(version: str, commit: str, epoch: int, archive: Path, files: dict[str, bytes], sources: dict) -> dict:
    document = {
        "spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"roc-zig-linker-inputs-{version}",
        "documentNamespace": f"https://spdx.org/spdxdocs/roc-zig-linker-inputs-{digest(archive)}",
        "creationInfo": {"created": datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                         "creators": ["Tool: roc-platform-template-zig-linker-input-builder"]},
        "packages": [{"SPDXID": "SPDXRef-inputs", "name": "roc-zig-linker-inputs", "versionInfo": version,
                      "downloadLocation": "NOASSERTION", "filesAnalyzed": False,
                      "licenseConcluded": "NOASSERTION", "licenseDeclared": "NOASSERTION",
                      "copyrightText": "NOASSERTION", "checksums": [{"algorithm": "SHA256", "checksumValue": digest(archive)}]}],
        "files": [], "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES",
                                           "relatedSpdxElement": "SPDXRef-inputs"}],
        "annotations": [{"annotationDate": datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                         "annotationType": "OTHER", "annotator": "Tool: roc-platform-template-zig-linker-input-builder",
                         "comment": json.dumps({"source_commit": commit, "sources": sources}, sort_keys=True)}],
    }
    for index, (name, data) in enumerate(sorted(files.items())):
        ident = f"SPDXRef-file-{index}"
        document["files"].append({"SPDXID": ident, "fileName": "./" + name,
                                  "checksums": [{"algorithm": "SHA256", "checksumValue": digest_bytes(data)}],
                                  "licenseConcluded": "NOASSERTION", "licenseInfoInFiles": ["NOASSERTION"],
                                  "copyrightText": "NOASSERTION"})
        document["relationships"].append({"spdxElementId": "SPDXRef-inputs", "relationshipType": "CONTAINS",
                                           "relatedSpdxElement": ident})
    return document


def build(output: Path) -> None:
    sources = json.loads(SOURCES.read_text())
    runtime_sources = json.loads((ROOT / "runtime/sources.json").read_text())
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="linker-inputs-", dir=ROOT / ".zig-cache") as temporary:
        work = Path(temporary)
        runtime_dist = work / "runtime-dist"
        run(["python3", ROOT / "scripts/build_runtime.py", "build", "--output", runtime_dist])
        runtime_archive = runtime_dist / f"roc-runtime-{runtime_sources['runtime_version']}.tar.gz"
        payload: dict[str, bytes] = {}
        with tarfile.open(runtime_archive, "r:gz") as tar:
            for target in ("x64musl", "arm64musl"):
                for name in RUNTIME_FILES:
                    member = f"targets/{target}/{name}"
                    payload[member] = tar.extractfile(member).read()
            for notice in ("licenses/Zig.txt", "licenses/musl.txt"):
                payload[notice] = tar.extractfile(notice).read()
        toolchain_work = work / "toolchain-download"
        toolchain_work.mkdir()
        zig = toolchain(toolchain_work, runtime_sources)
        audit_macos_catalog(zig, work, runtime_sources["objcopy"]["command"].replace("objcopy", "nm"))
        payload.update(windows_files(zig, work))
        mingw_notice = zig.parent / "lib/libc/mingw/COPYING"
        payload["licenses/mingw-w64.txt"] = mingw_notice.read_bytes()
        stub, catalog, provenance = macos_stub()
        for target in ("x64mac", "arm64mac"):
            payload[f"targets/{target}/libSystem.tbd"] = stub
        payload["sources/macos-libSystem.json"] = catalog
        payload["sources/macos-PROVENANCE.md"] = provenance
        payload["sources/sources.json"] = json_bytes(sources)
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        epoch = int(subprocess.check_output(["git", "show", "-s", "--format=%ct", "HEAD"], cwd=ROOT, text=True))
        fingerprint = digest_bytes(json_bytes({"sources": sources, "runtime_sources": runtime_sources, "files": sorted(payload)}))
        manifest = {"schema": 1, "version": sources["version"], "source_commit": commit,
                    "input_fingerprint": fingerprint,
                    "files": {name: {"sha256": digest_bytes(data), "size": len(data)} for name, data in sorted(payload.items())}}
        payload["dependency.json"] = json_bytes(manifest)
        archive = output / f"roc-zig-linker-inputs-{sources['version']}.tar.gz"
        write_archive(archive, payload)
        read_archive(archive)
        sbom_path = output / "linker-inputs.spdx.json"
        sbom_path.write_bytes(json_bytes(sbom(sources["version"], commit, epoch, archive, payload, sources)))
        sums = output / "SHA256SUMS"
        sums.write_text("".join(f"{digest(path)}  {path.name}\n" for path in sorted(output.iterdir()) if path.is_file()))
        asset_paths = (archive, sbom_path, sums)
        release = {
            "schema_version": 1,
            "release_tag": "linker-inputs-v" + sources["version"],
            "source": {"repository": "lukewilliamboswell/roc-platform-template-zig",
                       "commit": commit, "ref": "refs/heads/main"},
            "input_fingerprint": fingerprint,
            "targets": ["x64mac", "arm64mac", "x64win", "x64musl", "x64v1musl", "arm64musl", "arm64v1musl"],
            "assets": [{"name": path.name, "sha256": digest(path), "size": path.stat().st_size,
                        "role": ("archive" if path == archive else "sbom" if path == sbom_path else "checksums")}
                       for path in asset_paths],
            "dependencies": [{"name": "zig", "version": sources["zig_version"]}],
            "license_summary": "MIT and NOASSERTION; see SPDX and licenses in archive",
        }
        (output / "dependency.json").write_bytes(json_bytes(release))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    build(parser.parse_args().output.resolve())
