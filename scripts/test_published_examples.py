#!/usr/bin/env python3
"""Run the frozen examples from the highest SemVer platform release with an isolated cache.

The archive and its release platform URL are used unmodified; only the compiler pin
in temporary copies follows the current selection, so a compiler update is checked
against what users actually downloaded.
"""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

root = Path(__file__).resolve().parents[1]
(root / ".zig-cache").mkdir(exist_ok=True)


def latest_examples_asset() -> tuple[str, str]:
    """Pick the highest platform release; other release streams share this repository."""
    repo = os.environ.get("GITHUB_REPOSITORY", "lukewilliamboswell/roc-platform-template-zig")
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases?per_page=100",
        headers={"Accept": "application/vnd.github+json"},
    )
    if token := os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"):
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        releases = json.load(response)
    versions = [
        (tuple(map(int, m.groups())), release)
        for release in releases
        if not release["draft"] and not release["prerelease"]
        if (m := re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", release["tag_name"]))
    ]
    if not versions:
        raise SystemExit("No platform release with a SemVer tag was found")
    _, release = max(versions, key=lambda item: item[0])
    for asset in release["assets"]:
        if asset["name"].startswith("examples-") and asset["name"].endswith(".tar.gz"):
            return release["tag_name"], asset["browser_download_url"]
    raise SystemExit(
        f"Release {release['tag_name']} has no examples-*.tar.gz asset; "
        "publish a release that includes the frozen examples archive"
    )


tag, url = latest_examples_asset()
print(f"Testing frozen examples from release {tag}: {url}")
compiler = subprocess.check_output(
    [sys.executable, "scripts/roc_version.py"], cwd=root, text=True
).strip()
with tempfile.TemporaryDirectory(prefix="roc-published-", dir=root / ".zig-cache") as tmp:
    tmp = Path(tmp)
    archive = tmp / "examples.tar.gz"
    urllib.request.urlretrieve(url, archive)
    unpacked = tmp / "unpacked"
    unpacked.mkdir()
    top = subprocess.check_output(
        [sys.executable, "scripts/examples_archive.py", "extract", str(archive),
         str(unpacked), "--compiler", compiler],
        cwd=root, text=True,
    ).strip().splitlines()[-1]
    cache = tmp / "cache"
    cache.mkdir()
    env = os.environ.copy()
    env["ROC_CACHE_DIR"] = str(cache)
    env["XDG_CACHE_HOME"] = str(cache)
    env["LOCALAPPDATA"] = str(cache)
    subprocess.run(
        [sys.executable, "scripts/test.py", "--verbose",
         "--examples-dir", f"{top}/examples", "--spec", f"{top}/test_spec.json"],
        cwd=root, env=env, check=True,
    )
