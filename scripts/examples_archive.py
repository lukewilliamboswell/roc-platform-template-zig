#!/usr/bin/env python3
"""Package and unpack the frozen examples published with each platform release.

Repository examples use a relative path to the current platform source. A release
archive carries complete application folders whose headers point at that release's
immutable platform URL, plus the test spec that matches them.
"""
from __future__ import annotations

import argparse
import re
import shutil
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLATFORM_RE = re.compile(r'platform "[^"\n]+"')
COMPILER_RE = re.compile(r'roc: "[^"\n]+"')


def rewrite_header(text: str, *, platform: str | None = None, compiler: str | None = None) -> str:
    """Rewrite the platform and/or compiler in an application header, exactly once."""
    if platform is not None:
        text, count = PLATFORM_RE.subn(lambda _: f'platform "{platform}"', text, count=1)
        if count != 1:
            raise SystemExit("example header has no platform to rewrite")
    if compiler is not None:
        text, count = COMPILER_RE.subn(lambda _: f'roc: "{compiler}"', text, count=1)
        if count != 1:
            raise SystemExit("example header has no compiler pin to rewrite")
    return text


def rewrite_tree(examples: Path, **kwargs: str | None) -> int:
    apps = sorted(examples.glob("*/main.roc"))
    if not apps:
        raise SystemExit(f"no examples found under {examples}")
    for app in apps:
        app.write_text(rewrite_header(app.read_text(encoding="utf-8"), **kwargs), encoding="utf-8")
    return len(apps)


def build(args: argparse.Namespace) -> None:
    url = f"https://github.com/{args.repo}/releases/download/{args.version}/{args.bundle}"
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp) / f"examples-{args.version}"
        shutil.copytree(ROOT / "examples", stage / "examples")
        shutil.copy(ROOT / "scripts" / "test_spec.json", stage / "test_spec.json")
        rewrite_tree(stage / "examples", platform=url)
        with tarfile.open(args.output, "w:gz") as archive:
            archive.add(stage, arcname=stage.name)
    print(f"Created: {args.output}")


def extract(args: argparse.Namespace) -> None:
    """Unpack an archive, optionally selecting the compiler used to run its examples."""
    with tarfile.open(args.archive) as archive:
        archive.extractall(args.destination, filter="data")
    roots = [p for p in args.destination.iterdir() if p.is_dir()]
    if len(roots) != 1:
        raise SystemExit("examples archive must contain exactly one top-level directory")
    if args.compiler:
        rewrite_tree(roots[0] / "examples", compiler=args.compiler)
    print(roots[0])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    b.add_argument("--version", required=True)
    b.add_argument("--bundle", required=True, help="platform bundle file name")
    b.add_argument("--repo", required=True, help="OWNER/NAME")
    b.add_argument("--output", type=Path, required=True)
    b.set_defaults(run=build)
    e = sub.add_parser("extract")
    e.add_argument("archive", type=Path)
    e.add_argument("destination", type=Path)
    e.add_argument("--compiler", help="replace the compiler pin in the extracted copies")
    e.set_defaults(run=extract)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
