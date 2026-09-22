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

Linker-input changes are made on a same-repository pull-request branch. The
candidate workflow builds twice, exercises the native runtime, and attests the
exact archive and release manifest. From `main`, dispatch **Publish PR linker
inputs** with that PR number. The pinned automation controller verifies the PR
head, producer workflow, hashes, and attestations before publishing a release
whose tag is derived from the manifest hash; it then adds only
`link-inputs.lock.json` as a lease-guarded GitHub-signed commit to the PR.

This split is intentional: candidate code gets build authority but no release
or repository-write authority. The default-branch controller never executes PR
code. After the publisher infrastructure exists on `main`, every later required
linker-input change can be released and selected by the same material-change PR.

Versions live in `sources.json` and advance through reviewed changes independently
of Roc nightlies. Existing tags and releases are never overwritten. If a run
fails after reserving a tag or creating a draft, inspect the existing state and
prepare a reviewed recovery; rerunning does not replace it automatically.

The runtime producer and consumer have separate release lifecycles. Runtime
updates require a new candidate and a reviewed content-lock update;
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

The trusted publisher verifies provenance once when admitting a dependency.
Ordinary builds verify the reviewed archive size and SHA-256 on every use,
including cache hits. They do not query the attestation service or rebuild a
missing input: a cache miss downloads the exact locked asset. This makes the
common path cheap and offline when cached while preserving provenance at the
dependency-change boundary.

During the first rollout, `runtime/dependency.json` remains the compatibility
lock. Once the publisher adds `link-inputs.lock.json`, consumers prefer it; the
legacy lock can then be removed in a reviewed cleanup.

The first rollout is necessarily staged because the trusted publisher wrapper
must already exist on the default branch. Merge an infrastructure PR containing
the producer, consumer, wrapper, and compatibility read first. Then open an
adoption PR that removes the legacy path and lock, dispatch the default-branch
publisher for that PR, and let its signed lock-only commit make adoption green.
This one-time ordering constraint is not a reason to rebuild inputs in routine CI.

Files live in `.zig-cache/runtime/<sha256>/`. Each build verifies the archive
and extracted files before staging runtime files under the ignored
`platform/targets/` directories. A cache mismatch fails with an error; rerun
`fetch` to replace it with a newly verified download. Never edit the cached files.

Platform bundles use a clean, explicit inventory of source modules, required host
and runtime libraries, licenses and the runtime manifest. Unrelated local
libraries cannot enter the bundle. Final platform publication signs the tested
bundle and an SPDX SBOM that records the runtime release and its components.

Legacy pre-adoption releases retain downloadable provenance and SBOM bundles:

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
