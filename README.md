# Roc platform template for Zig

A template for building [Roc platforms](https://www.roc-lang.org/platforms) using [Zig](https://ziglang.org).

## Requirements

- [Zig](https://ziglang.org/download/) 0.15.2 or later
- [Roc](https://www.roc-lang.org/) (for bundling)

## Examples

Run examples with `roc examples/<name>.roc`:

| Example | Features Demonstrated | Run |
|---------|----------------------|-----|
| `hello.roc` | Basic stdout, string interpolation | `roc examples/hello.roc` |
| `exit.roc` | Exit codes with `Err(Exit(code))` | `roc examples/exit.roc` |
| `echo.roc` | `Stdin.line!`, interactive I/O | `roc examples/echo.roc` |
| `fizzbuzz.roc` | `while` loops, `var`/`$variables`, `match` | `roc examples/fizzbuzz.roc` |
| `sum_fold.roc` | `fold`, `Str.concat`, `Str.join_with` | `roc examples/sum_fold.roc` |
| `stderr.roc` | `Stderr.line!`, both output streams | `roc examples/stderr.roc` |
| `match.roc` | `match` expressions on booleans | `roc examples/match.roc` |
| `tests.roc` | `expect` keyword for testing | `roc test --verbose examples/tests.roc` |

## Building

```bash
# Build for all supported targets (cross-compilation)
zig build -Doptimize=ReleaseSafe

# Build for native platform only
zig build native -Doptimize=ReleaseSafe
```

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
| x64glibc | `platform/targets/x64glibc/libhost.a` |
| arm64mac | `platform/targets/arm64mac/libhost.a` |
| arm64win | `platform/targets/arm64win/host.lib` |
| arm64musl | `platform/targets/arm64musl/libhost.a` |
| arm64glibc | `platform/targets/arm64glibc/libhost.a` |
| arm32musl | `platform/targets/arm32musl/libhost.a` |
