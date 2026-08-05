#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "scripts" / "test_spec.json"
STAGES = ("check", "test", "build", "run")

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace")


class TestFailure(Exception):
    pass


def current_platform() -> str:
    return {
        "Darwin": "macos",
        "Linux": "linux",
        "Windows": "windows",
    }.get(platform.system(), platform.system().lower())


def command_text(args: list[str]) -> str:
    return subprocess.list2cmdline(args) if os.name == "nt" else " ".join(args)


def expand(value: str, source: Path) -> str:
    return value.format(root=ROOT, source=source, source_dir=source.parent)


def require_string_list(owner: str, value: object) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise TestFailure(f"{owner} must be an array of strings")
    return value


def run_cases(app: dict[str, object]) -> list[dict[str, object]]:
    cases = app.get("cases", [])
    if not isinstance(cases, list) or not all(isinstance(case, dict) for case in cases):
        raise TestFailure(f"{app['path']}: cases must be an array of objects")
    names = [case.get("name") for case in cases]
    if not all(isinstance(name, str) and name for name in names):
        raise TestFailure(f"{app['path']}: every case needs a non-empty string name")
    if len(names) != len(set(names)):
        raise TestFailure(f"{app['path']}: case names must be unique")
    return cases


def platform_override(item: dict[str, object]) -> dict[str, object]:
    platforms = item.get("platforms", {})
    if not isinstance(platforms, dict):
        raise TestFailure("platforms must be an object")
    override = platforms.get(current_platform(), {})
    if not isinstance(override, dict):
        raise TestFailure(f"platforms.{current_platform()} must be an object")
    return override


def stage_enabled(defaults: dict[str, bool], app: dict[str, object], stage: str) -> bool:
    enabled = app.get("enabled", True)
    if not isinstance(enabled, bool):
        raise TestFailure(f"{app['path']}: enabled must be a boolean")

    stage_value: object = defaults[stage]
    overrides = app.get("stages", {})
    if not isinstance(overrides, dict):
        raise TestFailure(f"{app['path']}: stages must be an object")
    if stage in overrides:
        stage_value = overrides[stage]

    platform_values = platform_override(app)
    platform_enabled = platform_values.get("enabled", True)
    if not isinstance(platform_enabled, bool):
        raise TestFailure(
            f"{app['path']}: platforms.{current_platform()}.enabled must be a boolean"
        )
    if stage in platform_values:
        stage_value = platform_values[stage]
    if not isinstance(stage_value, bool):
        raise TestFailure(f"{app['path']}: {stage} must be a boolean")
    return enabled and platform_enabled and stage_value


def case_enabled(source: Path, case: dict[str, object]) -> bool:
    enabled = case.get("enabled", True)
    if not isinstance(enabled, bool):
        raise TestFailure(f"{source} [{case.get('name')}]: enabled must be a boolean")
    override = platform_override(case)
    platform_enabled = override.get("enabled", True)
    if not isinstance(platform_enabled, bool):
        raise TestFailure(
            f"{source} [{case.get('name')}]: "
            f"platforms.{current_platform()}.enabled must be a boolean"
        )
    return enabled and platform_enabled


def load_spec(examples_dir: Path) -> tuple[dict[str, bool], list[dict[str, object]]]:
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    defaults = data.get("stages")
    apps = data.get("apps")
    if not isinstance(defaults, dict) or set(defaults) != set(STAGES):
        raise TestFailure(f"{SPEC_PATH}: stages must define {', '.join(STAGES)}")
    if not all(isinstance(defaults[name], bool) for name in STAGES):
        raise TestFailure(f"{SPEC_PATH}: all stage defaults must be booleans")
    if not isinstance(apps, list) or not all(isinstance(app, dict) for app in apps):
        raise TestFailure(f"{SPEC_PATH}: apps must be an array of objects")

    paths = [app.get("path") for app in apps]
    if not all(isinstance(path, str) for path in paths) or len(paths) != len(set(paths)):
        raise TestFailure(f"{SPEC_PATH}: every app needs a unique string path")

    discovered = {
        (Path("examples") / path.relative_to(examples_dir)).as_posix()
        for path in examples_dir.rglob("*.roc")
    }
    specified = set(paths)
    if discovered != specified:
        missing = sorted(discovered - specified)
        extra = sorted(specified - discovered)
        raise TestFailure(f"Test spec mismatch; missing={missing}, extra={extra}")

    for app in apps:
        if "run" in app:
            raise TestFailure(f"{app['path']}: use cases; singular run is not supported")
        cases = run_cases(app)
        if defaults["run"] and app.get("enabled", True) and not cases:
            raise TestFailure(f"{app['path']}: run is enabled but cases is empty")
    return defaults, apps


def source_path(app: dict[str, object], examples_dir: Path) -> Path:
    relative = Path(str(app["path"]))
    if not relative.parts or relative.parts[0] != "examples":
        raise TestFailure(f"{app['path']}: paths must be relative to examples/")
    return examples_dir.joinpath(*relative.parts[1:])


def print_output(stdout: str, stderr: str) -> None:
    if stdout:
        print(stdout, end="" if stdout.endswith("\n") else "\n")
    if stderr:
        print(stderr, end="" if stderr.endswith("\n") else "\n", file=sys.stderr)


def run_process(
    args: list[str],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    stdin: bytes | None = None,
    timeout: float = 30,
) -> subprocess.CompletedProcess[bytes]:
    print(f"+ {command_text(args)}", flush=True)
    try:
        return subprocess.run(
            args,
            cwd=cwd,
            env=env,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise TestFailure(f"Timed out after {timeout:g}s: {command_text(args)}") from error


def decode(data: bytes) -> str:
    return data.decode("utf-8", errors="replace")


def require_success(
    result: subprocess.CompletedProcess[bytes], description: str, *, verbose: bool
) -> None:
    stdout = decode(result.stdout)
    stderr = decode(result.stderr)
    if result.returncode != 0:
        print_output(stdout, stderr)
        raise TestFailure(f"{description}: exited with {result.returncode}")
    if verbose:
        print_output(stdout, stderr)


def verify_text(
    source: Path,
    case_name: str,
    stream: str,
    output: str,
    contains: object,
    regexes: object,
) -> None:
    normalized = output.replace("\r\n", "\n").replace("\r", "\n")
    if "[ROC CRASHED]" in normalized:
        raise TestFailure(f"{source} [{case_name}]: runtime crash\n{normalized}")
    expected_values = require_string_list(f"{source} [{case_name}] {stream}_contains", contains)
    patterns = require_string_list(f"{source} [{case_name}] {stream}_regex", regexes)
    for expected in expected_values:
        if expected not in normalized:
            raise TestFailure(
                f"{source} [{case_name}]: missing {stream} output {expected!r}"
                f"\n--- {stream} ---\n{normalized}"
            )
    for pattern_value in patterns:
        if re.search(pattern_value, normalized, re.MULTILINE) is None:
            raise TestFailure(
                f"{source} [{case_name}]: {stream} did not match {pattern_value!r}"
                f"\n--- {stream} ---\n{normalized}"
            )


def verify_output(
    source: Path, case_name: str, stdout: str, stderr: str, case: dict[str, object]
) -> None:
    verify_text(
        source,
        case_name,
        "combined",
        stdout + stderr,
        case.get("contains", []),
        case.get("regex", []),
    )
    verify_text(
        source,
        case_name,
        "stdout",
        stdout,
        case.get("stdout_contains", []),
        case.get("stdout_regex", []),
    )
    verify_text(
        source,
        case_name,
        "stderr",
        stderr,
        case.get("stderr_contains", []),
        case.get("stderr_regex", []),
    )


def make_environment(source: Path, case: dict[str, object]) -> dict[str, str]:
    env = os.environ.copy()
    unset_env = require_string_list(
        f"{source} [{case['name']}] unset_env", case.get("unset_env", [])
    )
    for name in unset_env:
        env.pop(name, None)
    values = case.get("env", {})
    if not isinstance(values, dict):
        raise TestFailure(f"{source} [{case['name']}]: env must be an object")
    for name, value in values.items():
        if not isinstance(name, str) or not isinstance(value, str):
            raise TestFailure(f"{source} [{case['name']}]: env values must be strings")
        env[name] = expand(value, source)
    return env


def run_case(
    source: Path, binary: Path, case: dict[str, object], *, verbose: bool
) -> None:
    case_name = str(case["name"])
    print(f"\n--- {source.relative_to(ROOT)} [{case_name}] ---")
    case_args = require_string_list(
        f"{source} [{case_name}] args", case.get("args", [])
    )
    args = [str(binary.resolve()), *(expand(value, source) for value in case_args)]
    if "stdin_hex" in case:
        try:
            stdin = bytes.fromhex(str(case["stdin_hex"]))
        except ValueError as error:
            raise TestFailure(f"{source} [{case_name}]: invalid stdin_hex") from error
    else:
        stdin_value = case.get("stdin", "")
        if not isinstance(stdin_value, str):
            raise TestFailure(f"{source} [{case_name}]: stdin must be a string")
        stdin = stdin_value.encode()

    temporary_cwd = (
        tempfile.TemporaryDirectory(prefix="roc-platform-template-case-")
        if case.get("temp_cwd")
        else None
    )
    cwd = (
        Path(temporary_cwd.name)
        if temporary_cwd
        else Path(expand(str(case.get("cwd", "{root}")), source))
    )
    try:
        result = run_process(
            args,
            cwd=cwd,
            env=make_environment(source, case),
            stdin=stdin,
            timeout=float(case.get("timeout", 10)),
        )
    finally:
        if temporary_cwd:
            temporary_cwd.cleanup()

    stdout = decode(result.stdout)
    stderr = decode(result.stderr)
    expected_exit = case.get("exit_code", 0)
    if not isinstance(expected_exit, int):
        raise TestFailure(f"{source} [{case_name}]: exit_code must be an integer")
    if verbose or result.returncode != expected_exit:
        print_output(stdout, stderr)
    if result.returncode != expected_exit:
        raise TestFailure(
            f"{source} [{case_name}]: exited with {result.returncode}, expected {expected_exit}"
        )
    verify_output(source, case_name, stdout, stderr, case)
    print(f"PASS run: {source.name} [{case_name}]")


def run_suite(
    examples_dir: Path, operation: str, *, verbose: bool
) -> dict[str, int]:
    defaults, apps = load_spec(examples_dir)
    selected = {
        "all": set(STAGES),
        "validate": {"check", "test"},
        "build": {"build"},
        "run": {"build", "run"},
    }[operation]
    counts = {stage: 0 for stage in STAGES}

    cache_dir = ROOT / ".zig-cache"
    cache_dir.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="roc-platform-template-tests-", dir=cache_dir
    ) as build_root:
        build_dir = Path(build_root)
        binaries: dict[str, Path] = {}

        for stage in STAGES:
            if stage not in selected:
                continue
            print(f"\n=== {stage.upper()} ===")
            for app in apps:
                if not stage_enabled(defaults, app, stage):
                    print(f"SKIP {stage}: {app['path']}")
                    continue
                source = source_path(app, examples_dir)
                if stage == "check":
                    result = run_process(["roc", "check", str(source), "--no-cache"])
                    require_success(result, f"check {source}", verbose=verbose)
                    print(f"PASS check: {source.name}")
                elif stage == "test":
                    result = run_process(["roc", "test", str(source), "--no-cache"])
                    require_success(result, f"test {source}", verbose=verbose)
                    print(f"PASS test: {source.name}")
                elif stage == "build":
                    relative = Path(str(app["path"])).relative_to("examples")
                    suffix = ".exe" if os.name == "nt" else ""
                    binary = build_dir / relative.with_suffix(suffix)
                    binary.parent.mkdir(parents=True, exist_ok=True)
                    build_args = require_string_list(
                        f"{source} build_args", app.get("build_args", [])
                    )
                    result = run_process(
                        [
                            "roc",
                            "build",
                            str(source),
                            f"--output={binary.relative_to(ROOT)}",
                            *build_args,
                        ]
                    )
                    require_success(result, f"build {source}", verbose=verbose)
                    binaries[str(app["path"])] = binary
                    print(f"PASS build: {source.name}")
                else:
                    binary = binaries.get(str(app["path"]))
                    if binary is None:
                        raise TestFailure(f"{app['path']}: run is enabled but build is disabled")
                    for case in run_cases(app):
                        if case_enabled(source, case):
                            run_case(source, binary, case, verbose=verbose)
                            counts[stage] += 1
                        else:
                            print(f"SKIP run: {source.name} [{case['name']}]")
                    continue
                counts[stage] += 1
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate, build, and run the platform examples from a shared test spec"
    )
    parser.add_argument("--examples-dir", type=Path, default=ROOT / "examples")
    parser.add_argument(
        "--operation",
        choices=("all", "validate", "build", "run"),
        default="all",
    )
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    if shutil.which("roc") is None:
        raise TestFailure("'roc' was not found on PATH")
    examples_dir = args.examples_dir
    if not examples_dir.is_absolute():
        examples_dir = ROOT / examples_dir
    examples_dir = examples_dir.resolve()
    if not examples_dir.is_dir():
        raise TestFailure(f"Examples directory does not exist: {examples_dir}")

    version = subprocess.check_output(["roc", "version"], text=True).strip()
    print(f"Using {version}")
    counts = run_suite(examples_dir, args.operation, verbose=args.verbose)
    completed = ", ".join(
        f"{stage}: {count}" for stage, count in counts.items() if count > 0
    )
    print(f"\nAll test stages passed ({completed})")


if __name__ == "__main__":
    try:
        main()
    except (json.JSONDecodeError, OSError, TestFailure) as error:
        raise SystemExit(str(error)) from None
