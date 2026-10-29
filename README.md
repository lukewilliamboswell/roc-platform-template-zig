# Roc platform template for Zig

A template for building Roc platforms with Zig.

[Read the manual](https://lukewilliamboswell.github.io/roc-platform-template-zig/) · [API reference](https://lukewilliamboswell.github.io/roc-platform-template-zig/api/)

## Quick start

Install the latest Roc nightly and roc-blueprint 0.10.0. Blueprint supplies Zig 0.17.0 and the fixed tooling compiler, `roc-stable`. Host builds also require Git, coreutils, tar, gzip, zip, unzip and GitHub CLI on PATH. Run these commands from the checkout:

```sh
blueprint run fetch-link-inputs
blueprint run build-release
roc examples/hello_world/main.roc
roc build examples/hello_world/main.roc
```

The example prints `Hello, World!`. The final command builds a standalone executable. Repository examples use the local platform. To start an independent project, download `roc-platform-template-zig-examples-VERSION.zip` from a platform release; its examples use the immutable released bundle.
