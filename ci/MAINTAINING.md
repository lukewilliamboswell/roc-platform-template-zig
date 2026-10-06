# Maintaining compiler compatibility

Follow the [Roc package maintainer guide](https://github.com/lukewilliamboswell/roc-automation/blob/b60d561cbd53c911b29238b30624827f8487113a/docs/package-maintainer-guide.md).
The workflow callers pin that reviewed revision; its nightly action uses
`ce402b2786852d7061dd6c91a6a118e886521e3c`. The pin reader in `scripts/` is vendored
from that action revision. Update it alongside the controller when its contract changes.

## Validation

Install Zig 0.16.0 and the compiler printed by `python3 scripts/roc_version.py`.
Run `python3 scripts/runtime.py fetch` before building from a fresh checkout.
`roc_version.py` checks agreement across the selected headers; `.github/roc-nightly.json`
lists paths, not another copy of the compiler version.

| Lane | Command | Input |
| --- | --- | --- |
| Published examples | `python3 scripts/test_published_examples.py` | The latest release's frozen `examples-*.tar.gz` and its immutable bundle URL, isolated caches; only the compiler pin is replaced in temporary copies |
| Current source | `bash ci/all_tests.sh` | Current host and platform; repository examples reference `../../platform/main.roc` |
| Release archive | `bash ci/test_bundled_examples.sh PATH_TO_BUNDLE` | Exact proposed archive served over loopback, temporary application copies |

Each lane checks, tests, builds and executes the cases in `scripts/test_spec.json`.
Companion modules are copied with each application. Published validation never
substitutes the local platform or rewrites the release URL. Compiler-only updates
advance metadata, not the platform release; an incompatible released platform
needs a repaired release, which publishes its own frozen examples.

## External linker-input changes

`link-inputs.lock.json` selects immutable external linker inputs. This is a
separate release from the Roc platform bundle below. Changing platform Roc
source or its compiler pin does not by itself require new linker inputs.

When `linker-inputs/` or another fingerprinted producer input changes:

1. Stage the source and recipe changes in a same-repository PR. Do not edit the
   lock by hand or run a publishing job from the PR branch.
2. Review the candidate and its target coverage. From `main`, dispatch
   **Publish PR linker inputs** with that PR number. The trusted controller
   dispatches `linker-inputs.yml` at the exact PR head; candidate jobs build,
   compare two independent outputs, assemble, and attest without release
   credentials.
3. The controller verifies the candidate evidence, publishes an immutable
   linker-input release, then adds only the new lock in a GitHub-signed commit
   to the PR. Review the release manifest, target archives, hashes, source SHA,
   and lock diff; rerun the PR checks on that new head before merging.

This publisher does not publish a Roc platform bundle or update application
URLs. Use the platform release procedure below when platform source or its
selected inputs change.

## Nightly blocked by the published platform

A new compiler may accept current source and its candidate bundle while rejecting
the older bundle pinned by public examples. The linker-input publisher above
cannot repair that failure: the platform bundle has its own `roc` requirement.
Keep the public check and immutable URLs intact while reviewing the source and
compiler-pin candidate, its exact commit, and the full current-source and bundle
test results.

The current platform release workflow publishes only from `main`. If strict
required checks prevent merging solely because the old published bundle fails,
the maintainer must review and explicitly authorize any one-time merge exception
for that exact candidate. Do not change required checks or enable a standing
bypass to make the updater green. After a reviewed merge, run the normal `main`
release workflow. It publishes a new frozen examples archive, which the
published-example check then uses; no example-URL PR is needed.

## Release procedure

Dispatch Release on a reviewed `main` commit with a new unprefixed package SemVer
(for example `1.1.0`). Exact-nightly bootstrap is explicitly enabled until a usable
stable compiler is adopted. The workflow validates the official compiler release,
source, proposed archive and documentation before publishing. It tags the event
SHA and uploads the tested bundle with its digest and exact compiler requirement.
Never move an existing tag or replace a released archive. If publication partially
succeeds, inspect the tag and assets and prepare a reviewed recovery; do not
blindly rerun publication.

The release also attaches `examples-VERSION.tar.gz`: complete application folders
and the matching `test_spec.json`, with each header pointing at that release's
immutable bundle URL and the publication compiler. Repository examples keep the
relative path `../../platform/main.roc` and are never edited after a release, so
there is no example-URL follow-up PR. Never replace an archive on an existing
release; a repair is a new release. The next CI run on any branch validates the
latest release's archive from a fresh cache. Check that the archive downloads
and its digest is in `SHA256SUMS`.

Rendered docs are ignored build output and deployed through Pages artifacts.
The existing site publishes one unversioned API snapshot. Versioned documentation,
and a user-facing starter generator beyond the frozen archive are
not implemented yet; preserve historical URLs when introducing versioned docs.
There is no automatic backport, stable compiler update, promotion or LTS policy.

## Live rollout

The September 7 updater failed at PR creation, before compiler validation:
[failed run](https://github.com/lukewilliamboswell/roc-platform-template-zig/actions/runs/34151289741).
Actions PR creation was disabled. The combined GitHub setting for creating and
approving PRs has now been enabled; default token permissions remain read-only.
The controller never approves its own PRs. `auto_merge` is enabled for signed,
compiler-pin-only candidates after both configured validation workflows pass.
The active `main` ruleset requires PRs, up-to-date `CI required` and `Bundle required`
checks from GitHub Actions, verified signatures, and protects against deletion and
force pushes. It has no bypass actors and requires zero human approvals so nightly
updates can merge unattended. This review-count policy applies to all PRs; source
and workflow changes still require maintainer review as project policy.

Both aggregate jobs run even after a dependency fails or is skipped and accept only
success from every lane. The controller mirrors their actual candidate results to
required statuses, then rechecks the base, head, signatures, and pin-only diff before
an immediate squash merge. Failed updates stay open. Set `auto_merge` to false to
stop automatic merging; disable the updater workflow for an immediate stop.
The repository allows all Actions; workflow dependencies remain pinned to reviewed
full commit SHAs. After changing this setup, manually dispatch Update Roc nightly
and verify the signed candidate, both configured workflow runs, and bot merge.
Repeat the dispatch to check the no-op path. Never infer protected-merge acceptance
from a successful validation dispatch alone.
