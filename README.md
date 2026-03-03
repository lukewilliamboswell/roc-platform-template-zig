# Roc platform template for Zig

A template for building [Roc platforms](https://www.roc-lang.org/platforms) using [Zig](https://ziglang.org).

## Requirements

- [Zig](https://ziglang.org/download/) 0.15.2 or later
- [Roc](https://www.roc-lang.org/) (for bundling)

## Examples

Run examples with interpreter: `roc examples/<name>.roc`

Build standalone executable: `roc build examples/<name>.roc`

## Testing

```
$ zig build test
roc Roc compiler version debug-c30871c6

  check: 12/12 passed
  run (interpreter): 10/10 passed
  build+run (compiled): 9/9 passed
  roc test: 2/2 passed

All 33 tests passed
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
| arm64mac | `platform/targets/arm64mac/libhost.a` |
| arm64win | `platform/targets/arm64win/host.lib` |
| arm64musl | `platform/targets/arm64musl/libhost.a` |

Linux musl targets include statically linked C runtime files (`crt1.o`, `libc.a`) for standalone executables.
