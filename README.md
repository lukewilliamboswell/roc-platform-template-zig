[![Roc-Lang][roc_badge]][roc_link]

[roc_badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Fpastebin.com%2Fraw%2FcFzuCCd7
[roc_link]: https://github.com/roc-lang/roc

# Roc platform template for Zig

A template for building [Roc platforms](https://www.roc-lang.org/platforms) using [Zig](https://ziglang.org).

## Requirements

- [Zig](https://ziglang.org/download/) 0.16.0 or later
- [Roc](https://github.com/roc-lang/nightlies/releases): install the exact nightly named by the `roc` field in the application header. The platform header declares the development compiler.

## Examples

The examples use [platform release 1.0.0](https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/tag/1.0.0), tested with the compiler declared in each header. Install that compiler, then run an example directly:

```bash
roc version
roc examples/hello_world/main.roc
# Hello, World!

printf 'Ada\n' | roc examples/echo/main.roc
```

Each folder in `examples/` is a complete application. Copy the whole folder,
including its pinned compiler and immutable platform URL. The header declares a
compiler requirement; it does not install or select the executable.

Build a standalone executable: `roc build examples/hello_world/main.roc`.

## Documentation

Platform API docs are published at <https://lukewilliamboswell.github.io/roc-platform-template-zig/>.

Generate docs locally:

```bash
zig build docs
```

## Testing

The checked-in examples pin a published release bundle so they can be copied directly. `zig build test` rewrites temporary copies to use the local `platform/main.roc` before running them.

[`scripts/test_spec.json`](scripts/test_spec.json) is the source of truth for example coverage. Every example has one entry and can define any number of named cases. A case can provide command-line arguments, stdin, environment variables, an expected exit code, and combined or stream-specific output assertions. The runner builds each example once and reuses that binary for all of its cases on Linux, macOS, and Windows.

```
$ zig build test
All test stages passed (check: 12, test: 2, build: 12, run: 17)
```

Run the spec directly against another examples directory or only selected stages:

```bash
python3 scripts/test_published_examples.py  # committed URLs, fresh cache
python3 scripts/test.py --operation validate
python3 scripts/test.py --operation run
```

## Building

```bash
# Build for all supported targets (cross-compilation)
zig build -Doptimize=ReleaseSafe

# Build for native platform only
zig build native -Doptimize=ReleaseSafe
```

## Regenerating Glue

When the platform API changes (e.g. adding or modifying hosted functions in `platform/main.roc`), regenerate the Zig glue:

```bash
roc glue <path-to-roc>/src/glue/src/ZigGlue.roc ./src/ ./platform/main.roc
```

This updates `src/roc_platform_abi.zig` with the ABI types and dispatch table matching the platform's hosted functions.

## Bundling

```bash
./bundle.sh
```

This creates a `.tar.zst` bundle containing all `.roc` files and prebuilt host libraries.

## Supported Targets

| Target | Library |
|--------|---------|
| x64mac | `platform/targets/x64mac/libhost.a` |
| x64win | `platform/targets/x64win/host.lib` |
| x64musl | `platform/targets/x64musl/libhost.a` |
| x64v1musl | `platform/targets/x64v1musl/libhost.a` |
| arm64mac | `platform/targets/arm64mac/libhost.a` |
| arm64win | `platform/targets/arm64win/host.lib` |
| arm64musl | `platform/targets/arm64musl/libhost.a` |
| arm64v1musl | `platform/targets/arm64v1musl/libhost.a` |

Linux musl targets include statically linked C runtime files (`crt1.o`, `libc.a`) for standalone executables. The `v1` targets use each architecture's baseline instruction set for CPUs without the features required by the default targets.

## Maintenance and releases

`main` tracks an exact nightly. The updater advances the platform and all public
example compiler headers together, preserving released platform URLs. CI has
separate **Published examples** and **Current source** jobs; release validation
also tests the exact proposed archive. A compiler update must pass all three.
Automatic merging is disabled; compiler compatibility failures need review.

Publication currently uses the explicit exact-nightly bootstrap policy, with no
stable compiler or LTS promise. Package versions are independent of compiler
versions. The release workflow checks that policy, rejects existing tags, tests
source and bundles, and publishes the tested commit with its compiler requirement
and SHA-256 digest. Nightly validation cannot publish or deploy.

See [the maintainer procedure](ci/MAINTAINING.md) for release follow-ups and the
remaining live rollout checks.
