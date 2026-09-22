# Independently released linker inputs

This directory defines the single `linker-inputs-vX.Y.Z` release stream. It
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

After the first signed release is published, copy its emitted
`linker-inputs.lock.json` to the repository root. Until then the existing signed
Linux runtime remains active; a lock with invented hashes is never accepted.

The consumer verifies online GitHub build-provenance attestations for both the
archive and SPDX document. The lock independently binds the archive and SBOM
digests, producer commit, reusable signer repository, workflow, and signer SHA;
there are no detached Sigstore bundle assets to redistribute.
