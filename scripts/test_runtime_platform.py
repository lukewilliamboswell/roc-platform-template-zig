#!/usr/bin/env python3
"""Test candidate runtime archives without changing the committed platform."""
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from runtime_common import ROOT, RUNTIME_FILES, safe_extract, runtime_members, validate_tree


def main(archive):
    (ROOT / ".zig-cache").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="runtime-platform-", dir=ROOT / ".zig-cache") as tmp:
        work = Path(tmp)
        for name in ("src", "scripts", "ci", "examples"):
            shutil.copytree(ROOT / name, work / name, ignore=shutil.ignore_patterns("__pycache__"))
        for name in ("build.zig", "build.zig.zon"):
            shutil.copyfile(ROOT / name, work / name)
        (work / "platform").mkdir()
        for source in (ROOT / "platform").glob("*.roc"):
            shutil.copyfile(source, work / "platform" / source.name)
        runtime = work / "runtime"
        safe_extract(archive, runtime, expected=runtime_members())
        validate_tree(runtime)
        for target in ("x64musl", "x64v1musl", "arm64musl", "arm64v1musl"):
            dest = work / "platform/targets" / target
            dest.mkdir(parents=True)
            for name in RUNTIME_FILES:
                shutil.copyfile(runtime / "targets" / target.replace("v1", "") / name, dest / name)
        header = work / "platform/main.roc"
        header.write_text(header.read_text().replace('"libc.a"]', '"libc.a", "libzigc.a", "libcompiler_rt.a"]'))
        build = work / "build.zig"
        build.write_text(build.read_text().replace("copy_all.step.dependOn(&runtime_stage.step);", "").replace("copy_native.step.dependOn(&runtime_stage.step);", "").replace('host_lib.bundle_compiler_rt = true;', 'host_lib.bundle_compiler_rt = target.result.os.tag != .linux;'))
        subprocess.run(["zig", "build", "test"], cwd=work, check=True)
        baseline = {"x86_64": "x64v1musl", "aarch64": "arm64v1musl"}[platform.machine()]
        spec_path = work / "scripts/test_spec.json"
        spec = json.loads(spec_path.read_text())
        for app in spec["apps"]:
            app.setdefault("build_args", []).append("--target=" + baseline)
        spec_path.write_text(json.dumps(spec))
        subprocess.run([sys.executable, "scripts/test.py", "--examples-dir", ".zig-cache/local-examples/examples"], cwd=work, check=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
