#!/usr/bin/env python3
"""Describe the tested bundle and its verified transitive runtime inventory."""
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys

from linker_inputs import load_lock, check
from linker_inputs_common import ROOT, digest
from runtime_common import write_json


def generate(archive: Path, output: Path):
    tree, manifest = check()
    lock = load_lock()
    inventory = json.loads((ROOT / ".zig-cache/platform-bundle.json").read_text())
    if inventory["archive"] != archive.name or inventory["sha256"] != digest(archive) or inventory["linker_inputs"] != lock:
        raise ValueError("SBOM inventory does not match this bundle and linker-input lock")
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    epoch = int(subprocess.check_output(["git", "show", "-s", "--format=%ct", "HEAD"], cwd=ROOT))
    packages = [{"SPDXID": "SPDXRef-inputs", "name": "roc-zig-link-inputs",
                 "versionInfo": manifest["version"], "downloadLocation": lock["url"],
                 "filesAnalyzed": True, "licenseConcluded": "NOASSERTION",
                 "licenseDeclared": "NOASSERTION", "copyrightText": "NOASSERTION",
                 "checksums": [{"algorithm": "SHA256", "checksumValue": lock["sha256"]}]}]
    packages.append({"SPDXID": "SPDXRef-platform", "name": "roc-platform-template-zig", "versionInfo": sha,
                     "downloadLocation": "NOASSERTION", "filesAnalyzed": False, "licenseConcluded": "NOASSERTION",
                     "licenseDeclared": "NOASSERTION", "copyrightText": "NOASSERTION",
                     "checksums": [{"algorithm": "SHA256", "checksumValue": digest(archive)}]})
    relationships = [
        {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-platform"},
        {"spdxElementId": "SPDXRef-platform", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-inputs"},
    ]
    files = []
    for index, (name, record) in enumerate(sorted(manifest["files"].items())):
        ident = f"SPDXRef-input-file-{index}"
        if digest(tree / name) != record["sha256"]:
            raise ValueError("Staged linker-input file differs from dependency inventory")
        files.append({"SPDXID": ident, "fileName": "./" + name,
                      "checksums": [{"algorithm": "SHA256", "checksumValue": record["sha256"]}],
                      "licenseConcluded": "NOASSERTION", "licenseInfoInFiles": ["NOASSERTION"],
                      "copyrightText": "NOASSERTION"})
        relationships.append({"spdxElementId": "SPDXRef-inputs", "relationshipType": "CONTAINS",
                              "relatedSpdxElement": ident})
    for index, (name, checksum) in enumerate(sorted(inventory["files"].items())):
        ident = f"SPDXRef-platform-file-{index}"
        files.append({"SPDXID": ident, "fileName": "./" + name, "checksums": [{"algorithm": "SHA256", "checksumValue": checksum}],
                      "licenseConcluded": "NOASSERTION", "licenseInfoInFiles": ["NOASSERTION"], "copyrightText": "NOASSERTION"})
        relationships.append({"spdxElementId": "SPDXRef-platform", "relationshipType": "CONTAINS", "relatedSpdxElement": ident})
    compiler_pin = subprocess.check_output([sys.executable, "scripts/roc_version.py"], cwd=ROOT, text=True).strip()
    for ident, name, version in [("platform-zig", "Zig host compiler", subprocess.check_output(["zig", "version"], text=True).strip()),
                                  ("roc", "Roc bundler", compiler_pin)]:
        packages.append({"SPDXID": f"SPDXRef-{ident}", "name": name, "versionInfo": version, "downloadLocation": "NOASSERTION",
                         "filesAnalyzed": False, "licenseConcluded": "NOASSERTION", "licenseDeclared": "NOASSERTION", "copyrightText": "NOASSERTION"})
        relationships.append({"spdxElementId": f"SPDXRef-{ident}", "relationshipType": "BUILD_TOOL_OF", "relatedSpdxElement": "SPDXRef-platform"})
    write_json(output, {"spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
                        "name": "roc-platform-template-zig", "documentNamespace": f"https://spdx.org/spdxdocs/roc-platform-{digest(archive)}",
                        "creationInfo": {"created": datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                         "creators": ["Tool: roc-platform-template-zig-sbom"]},
                        "packages": packages, "files": files, "relationships": relationships})


if __name__ == "__main__":
    generate(Path(sys.argv[1]).resolve(), Path(sys.argv[2]))
