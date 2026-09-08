# Maintaining compiler compatibility

Follow the [Roc package maintainer guide](https://github.com/lukewilliamboswell/roc-automation/blob/b60d561cbd53c911b29238b30624827f8487113a/docs/package-maintainer-guide.md).
The workflow callers pin that reviewed revision; its nightly action uses
`ce402b2786852d7061dd6c91a6a118e886521e3c`. The pin reader in `scripts/` is vendored
from that action revision. Update it alongside the controller when its contract changes.

## Validation

Install Zig 0.16.0 and the compiler printed by `python3 scripts/roc_version.py`.
That command checks agreement across the selected headers; `.github/roc-nightly.json`
lists paths, not another copy of the compiler version.

| Lane | Command | Input |
| --- | --- | --- |
| Published examples | `python3 scripts/test_published_examples.py` | Committed application folders and immutable release URLs, isolated caches |
| Current source | `bash ci/all_tests.sh` | Current host and platform, temporary application copies |
| Release archive | `bash ci/test_bundled_examples.sh PATH_TO_BUNDLE` | Exact proposed archive served over loopback, temporary application copies |

Each lane checks, tests, builds and executes the cases in `scripts/test_spec.json`.
Companion modules are copied with each application. Public validation never
substitutes the local platform. Keep URLs unchanged in compiler-only updates;
an incompatible published platform may require a new release and reviewed URL
update before the compiler update can pass.

## Release procedure

Dispatch Release on a reviewed `main` commit with a new unprefixed package SemVer
(for example `1.1.0`). Exact-nightly bootstrap is explicitly enabled until a usable
stable compiler is adopted. The workflow validates the official compiler release,
source, proposed archive and documentation before publishing. It tags the event
SHA and uploads the tested bundle with its digest and exact compiler requirement.
Never move an existing tag or replace a released archive. If publication partially
succeeds, inspect the tag and assets and prepare a reviewed recovery; do not
blindly rerun publication.

Release follow-ups remain manual:

1. Prepare a separate branch updating example platform URLs and README release
   links to the published asset. Preserve compiler pins and companion modules.
2. Run published-example validation against those actual URLs from a fresh cache.
   A starter download, when provided, must include complete application folders,
   pinned headers and compiler installation instructions; test its extracted files.
3. Open a signed, reviewed follow-up PR and verify checks on its current commit.
   A bot-created PR may need approval to start workflows; a green workflow dispatch
   alone does not satisfy unrelated required PR checks.

Rendered docs are ignored build output and deployed through Pages artifacts.
The existing site publishes one unversioned API snapshot. Versioned documentation,
downloadable starter generation, and automated signed release follow-up PRs are
not implemented yet; preserve historical URLs when introducing versioned docs.
There is no automatic backport, stable compiler update, promotion or LTS policy.

## Live rollout

The September 7 updater failed at PR creation, before compiler validation:
[failed run](https://github.com/lukewilliamboswell/roc-platform-template-zig/actions/runs/34151289741).
Actions PR creation was disabled. The combined GitHub setting for creating and
approving PRs has now been enabled; default token permissions remain read-only.
The controller never approves its own PRs, and `auto_merge` is explicitly false.
The repository currently allows all Actions and has no effective rules on `main`.

After merging these changes, manually dispatch Update Roc nightly. Verify the
signed candidate commit, both CI lanes and release archive jobs against that SHA.
Then exercise a no-op and retain failure evidence showing unsuccessful updates
remain unmerged. These live trials have not been completed by local validation.

Before enabling automatic merging, install and verify strict required-check and
PR rules with no bot bypass, following the shared integration guide. Select real
check names from successful runs. Do not infer protected-merge acceptance from a
successful dispatch or enable automatic merging merely to report statuses.
