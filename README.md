[![Roc-Lang][roc_badge]][roc_link]

[roc_badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Froc-lang.org%2Fbadge%2Froc.json
[roc_link]: https://github.com/roc-lang/roc

# Roc platform template for Zig

A template for building [Roc platforms](https://www.roc-lang.org/platforms) using [Zig](https://ziglang.org).

## Requirements

- [Zig](https://ziglang.org/download/) 0.17.0
- [Roc](https://github.com/roc-lang/nightlies/releases): the latest nightly. The platform and its examples name no compiler.
- [roc-blueprint](https://github.com/lukewilliamboswell/roc-blueprint) for the repository tasks. It provides Zig and `roc-stable`, the fixed nightly that runs the scripts in `scripts/`, from `Blueprint.roc`.

## Examples

Each folder in `examples/` is a complete application that names this checkout's
platform by relative path, so it runs against the source here:

```bash
blueprint run fetch-link-inputs   # once, on a fresh checkout
zig build
roc examples/hello_world/main.roc
# Hello, World!

printf 'Ada\n' | roc examples/echo/main.roc
```

To start a project, download `roc-platform-template-zig-examples-VERSION.zip`
from a [release](https://github.com/lukewilliamboswell/roc-platform-template-zig/releases):
its examples name that release's immutable bundle URL instead.

Build a standalone executable: `roc build examples/hello_world/main.roc`.

## Documentation

Platform API docs are published at <https://lukewilliamboswell.github.io/roc-platform-template-zig/>.

Generate docs locally:

```bash
zig build docs
```

## Testing

[`tests/spec.json`](tests/spec.json) records every example's cases: the
arguments, standard input, and the exact standard output, standard error and
exit code expected. It uses the same format as the release archive and the
shared [nightly compatibility](https://github.com/lukewilliamboswell/roc-automation)
runner.

```bash
blueprint run check              # compiler pins, compiled artifacts, the scripts, Zig formatting
zig build test                   # host unit tests, then every example against tests/spec.json
blueprint run test -- --update   # record what the examples print now, for review
```

## Building

`link-inputs.lock.json` selects the external linker inputs. Fetch them once;
every build verifies their size and SHA-256 and works offline afterwards.

```bash
zig build fetch-link-inputs

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
blueprint run bundle
```

This creates a `.tar.zst` bundle of the platform's `.roc` files, the host
libraries and the locked linker inputs, from an explicit inventory.

## Supported Targets

| Target | Library |
|--------|---------|
| x64mac | `platform/targets/x64mac/libhost.a` |
| x64win | `platform/targets/x64win/host.lib` |
| x64musl | `platform/targets/x64musl/libhost.a` |
| x64v1musl | `platform/targets/x64v1musl/libhost.a` |
| arm64mac | `platform/targets/arm64mac/libhost.a` |
| arm64musl | `platform/targets/arm64musl/libhost.a` |
| arm64v1musl | `platform/targets/arm64v1musl/libhost.a` |

Linux musl targets include verified runtime files (`crt1.o`, `libc.a`, `libzigc.a`, `libcompiler_rt.a`) for standalone executables. The Windows target includes a startup archive (`msvc_runtime.lib`) and import archives for the Universal CRT and system DLLs, so linking needs no Windows SDK or Visual Studio. The `v1` targets use each architecture's baseline instruction set for CPUs without the features required by the default targets.

ARM64 Windows is intentionally not advertised: release validation cannot yet
execute that target natively. External linker inputs use the single signed,
content-addressed `linker-inputs-vX.Y.Z` stream documented in
[`linker-inputs/README.md`](linker-inputs/README.md). Host archives continue to
be built from the platform source in this checkout and are not release inputs.

## Maintenance and releases

The repository follows [roc-automation](https://github.com/lukewilliamboswell/roc-automation):
CI tests the working tree with the latest Roc nightly, `release.yml` builds and
tests the exact bundle and examples archive it would publish, and
`nightly.yml` runs the latest release's archived examples against each new
nightly. See [MAINTAINING.md](MAINTAINING.md).

Runtime sources, independent releases and verification are described in [runtime/README.md](runtime/README.md).
