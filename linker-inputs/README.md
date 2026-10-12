# Independently released linker inputs

This directory defines the single aggregate linker-input release stream. It
contains every external linker input used by the advertised targets; host
archives remain products of the current platform source and are deliberately
excluded.

The release archive is deterministic and includes Linux musl/Zig runtime files,
the x86-64 Windows inputs described below, and a project-authored dual-arch
TAPI v4 `libSystem.tbd`. The latter is generated only from the reviewed catalog;
the build does not read an Apple SDK.

Roc links an `x64win` executable from the inputs the platform lists and takes
nothing from the machine: no Windows SDK, no Visual Studio, no default
libraries. The archive supplies both kinds of input that needs:

- `msvc_runtime.lib`, built here for `x86_64-windows-msvc`: the `mainCRTStartup`
  entry point, which gets `argc` and `argv` from the Universal CRT and calls the
  host's C `main`; the TLS directory; and Zig's compiler-rt. Its three source
  files are in [`msvc-runtime/`](msvc-runtime), copied unchanged from the Roc
  commit that [`UPSTREAM.json`](msvc-runtime/UPSTREAM.json) records with their
  SHA-256 values. The producer refuses a file that differs.
- Import archives for the Universal CRT that ships with Windows and for
  `kernel32`, `ntdll`, `advapi32`, `shell32` and `user32`, as Zig generates them
  from its mingw-w64 definitions. They name DLL exports and hold no code.

The producer then links the host of this checkout against exactly those files,
with `/nodefaultlib` and no `/entry`, so a missing symbol stops the build before
anything is released.

Build twice and compare the outputs:

```sh
python3 scripts/build_linker_inputs.py --output .zig-cache/linker-inputs-1
python3 scripts/build_linker_inputs.py --output .zig-cache/linker-inputs-2
diff -r .zig-cache/linker-inputs-1 .zig-cache/linker-inputs-2
```

Material changes are built by the dispatch-only `linker-inputs.yml` workflow on
a same-repository PR branch. The default-branch publisher verifies its exact
commit, workflow, hashes, inventory, and attestations, then publishes under a
manifest-derived content identity and adds only `linker-inputs.lock.json` as a
signed commit to that PR. Routine PRs only restore or download the locked bytes;
they never run this producer.

The publisher verifies GitHub provenance at admission. Routine consumers require
its generated lock, verify the committed size and SHA-256 even on cache hits, and
make no network request for a valid cached archive.
