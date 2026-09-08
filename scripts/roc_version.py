#!/usr/bin/env python3
"""Read the agreed compiler requirement from the configured Roc headers."""
import json
from pathlib import Path

from compiler_pins import discover, local_sources, version

root = Path(__file__).resolve().parents[1]
config = json.loads((root / ".github/roc-nightly.json").read_text())
if (root / ".roc-version").exists():
    raise SystemExit("Remove .roc-version: compiler headers are the version authority")
print(version(discover(local_sources(root, config["compiler_roots"]))))
