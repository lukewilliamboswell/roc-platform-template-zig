# Independently released Linux runtime

`sources.json` pins the official Zig distribution, its SHA-256 and upstream
Minisign key. The producer verifies both before executing Zig and compiling its
bundled musl, Zig libc and compiler runtime. This does not bootstrap Zig itself.

The archive contains baseline x86-64 and ARM64 Linux runtime files, a per-file
manifest, and license notices. Zig 0.16.0 supplies musl 1.2.5 with Zig-specific
changes; the SBOM does not describe this as unmodified upstream musl.

To reproduce on Linux, install Python 3.10+ and Minisign, then run:

```sh
python3 scripts/build_runtime.py build --output .zig-cache/runtime-dist
python3 scripts/build_runtime.py smoke .zig-cache/runtime-dist/roc-runtime-1.0.0.tar.gz
```

Output directories must be new. Two independent CI builds must produce identical
archives and SBOMs. Native x86-64 and ARM64 jobs test startup, allocation, math,
threads, TLS and stdio with only the archive's runtime libraries. Candidate Roc
tests use temporary platform copies, including baseline target builds.

After a reviewed producer change merges to `main`, manually dispatch **Runtime
release**. Compilation and testing have read-only permissions. The publishing
job performs no source checkout, signs provenance and SPDX SBOM attestations for
the tested archive, and publishes a draft only after attaching all assets.
Enable repository release immutability before the first publication. Runtime
tags use `runtime-VERSION` and never become the latest platform release.

Versions live in `sources.json` and advance through reviewed changes independently
of Roc nightlies. Existing tags and releases are never overwritten. If a run
fails after reserving a tag or creating a draft, inspect the existing state and
prepare a reviewed recovery; rerunning does not replace it automatically.

The initial producer leaves the historical runtime files in Git until the first
published archive and its attestations have been verified. The consumer migration
then removes those files going forward, without rewriting Git history.

Attestations prove the recorded build identity and artifact integrity. They do
not constitute an OpenSSF certification or an asserted SLSA level.
