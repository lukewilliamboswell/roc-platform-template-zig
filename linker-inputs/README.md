# Independently released linker inputs

This directory defines the single aggregate linker-input release stream. It
contains every external linker input used by the advertised targets; host
archives remain products of the current platform source and are deliberately
excluded.

The release archive is deterministic and includes Linux musl/Zig runtime files,
x86-64 MinGW runtime and system import archives, and a project-authored dual-arch
TAPI v4 `libSystem.tbd`. The latter is generated only from the reviewed catalog;
the build does not read an Apple SDK.

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

The publisher verifies GitHub provenance at admission. Routine consumers verify
the committed size and SHA-256 even on cache hits and make no network request for
a valid cached archive. The existing SemVer lock remains a staged compatibility
read until the first publisher-generated lock lands; it must then be removed.
