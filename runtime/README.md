# Independently released Linux runtime

`sources.json` pins the official Zig distribution, its SHA-256 and upstream
Minisign key. The producer verifies both before executing Zig and compiling its
bundled musl, Zig libc and compiler runtime. This does not bootstrap Zig itself.

The archive strips build-path-bearing debug data with LLVM objcopy and contains baseline x86-64 and ARM64 Linux runtime files, a per-file
manifest, and license notices. Zig 0.16.0 supplies musl 1.2.5 with Zig-specific
changes; the SBOM does not describe this as unmodified upstream musl.

To reproduce on Linux, install Python 3.10+, Minisign and LLVM 18.1.3 (`llvm-objcopy-18`), then run:

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

The runtime producer and consumer have separate release lifecycles. Runtime
updates require a new producer version and a reviewed update of `dependency.json`;
Roc nightly updates do not change that lock. Historical Git commits are preserved.

## Platform contributors

Install Python 3.10+ and GitHub CLI 2.98+ alongside Zig and Roc. Fetch the pinned
runtime before building from a fresh checkout:

```sh
python3 scripts/runtime.py fetch
zig build
zig build test
./bundle.sh
```

Setup verifies the archive and SBOM hashes and both Sigstore attestations. It
requires the locked repository, workflow, source commit, and `main` ref, and
rejects self-hosted signers. There is no unsigned fallback. GitHub CLI fetches
Sigstore trust metadata during setup; normal builds only check local hashes and
work offline. In CI, setup uses the read-only job token. Locally, use `gh auth
login` if the CLI requests authentication.

Files live in `.zig-cache/runtime/<sha256>/`. Each build verifies the archive,
its SBOM, and the extracted files before staging runtime files under the ignored
`platform/targets/` directories. A cache mismatch fails with an error; rerun
`fetch` to replace it with a newly verified download. Never edit the cached files.

Platform bundles use a clean, explicit inventory of source modules, required host
and runtime libraries, licenses and the runtime manifest. Unrelated local
libraries cannot enter the bundle. Final platform publication signs the tested
bundle and an SPDX SBOM that records the runtime release and its components.

To verify downloads yourself:

```sh
gh attestation verify roc-runtime-1.0.0.tar.gz --repo lukewilliamboswell/roc-platform-template-zig --bundle provenance.sigstore.json
gh attestation verify roc-runtime-1.0.0.tar.gz --repo lukewilliamboswell/roc-platform-template-zig --bundle sbom.sigstore.json --predicate-type https://spdx.dev/Document/v2.3
```

For platform releases, use the `.tar.zst` bundle and the corresponding
`platform-provenance.sigstore.json` / `platform-sbom.sigstore.json` assets.
`runtime.py fetch` adds the stricter identity and commit constraints from the
reviewed dependency lock to the commands above.

Attestations prove the recorded build identity and artifact integrity. They do
not constitute an OpenSSF certification or an asserted SLSA level.
