# Maintaining the platform

This repository follows
[roc-automation](https://github.com/lukewilliamboswell/roc-automation): the
platform and its examples name no compiler and are tested with the latest Roc
nightly; the automation is Roc scripts under `scripts/`, run by `roc-stable`,
the fixed nightly `Blueprint.roc` fetches; and three workflows answer three
questions.

| Workflow | Question | Runs |
| --- | --- | --- |
| `ci.yml` | Does the working tree work with the latest nightly? | `blueprint run check`; on every release target, `zig build test` (host unit tests, then every example against `tests/spec.json`) |
| `release.yml` | Do the exact bundle and examples archive a release would publish work? | `blueprint run release -- build VERSION` on Linux, then `scripts/release.roc -- test-archive` on every release target, with the bundle served over loopback and an empty package cache |
| `nightly.yml` | Does the latest release still work with the latest nightly? | The shared runner on the release's `roc-platform-template-zig-examples-VERSION.zip` |

`CI required` and `Bundle required` are the required checks on `main`.

## Local tasks

```bash
blueprint run check                      # pins, compiled artifacts, the scripts' tests and formatting, Zig formatting
blueprint run fetch-link-inputs          # the locked linker inputs, once per checkout
zig build test                           # host unit tests, then the examples (needs roc-stable on PATH: blueprint shell)
blueprint run test -- --update           # record what the examples print in tests/spec.json
blueprint run build-release              # the host with -Doptimize=ReleaseSafe, as a release ships it
blueprint run release -- build 0.0.1-dryrun   # dist/, tested over loopback
```

The latest nightly must be on `PATH` as `roc`. On Windows and Intel macOS,
where Blueprint does not run, CI installs `roc-stable` with
`.github/actions/setup-toolchain`, from the tag `Blueprint.roc` names.

## A new Roc nightly

Nothing in the repository names the nightly, so there is no pin to update. A
nightly that breaks the working tree fails CI on the next pull request; fix the
source. A nightly that breaks the latest release fails `nightly.yml`, which
opens one tracking issue: fix the source if needed and publish a patch release.
Its archive is what the next nightly run tests, and a pass closes the issue.

The scripts' compiler, `roc-stable`, changes only on purpose: update the tag in
`Blueprint.roc` and the `roc` field of every script together, format the
scripts with the new `roc-stable fmt`, and run `blueprint update`.
`scripts/check_no_pins.roc` keeps the two in step.

## Release procedure

Dispatch **Release** on `main` with a new `MAJOR.MINOR.PATCH`. The workflow
builds the bundle, the examples archive and the SBOM, tests the archive against
the bundle on every release target, attests the bundle and its SBOM, then
publishes the tested files with roc-automation's `publish-release`, which
verifies every uploaded asset against the tested file. Pull requests run the
same steps with the version `0.0.1-dryrun` and publish nothing.

The examples archive holds the repository's examples, `spec.json` and a README;
each example differs from the repository's only in naming the release's bundle
URL instead of `../../platform/main.roc`. Repository examples are never edited
after a release. Never move an existing tag or replace a released asset; a
repair is a new release.

## External linker-input changes

`link-inputs.lock.json` selects immutable external linker inputs. This is a
separate release from the platform bundle. Changing platform Roc source does
not by itself require new linker inputs. `zig build` fetches, verifies and
stages them with `tools/link_inputs.zig`.

When `linker-inputs/` or another fingerprinted producer input changes:

1. Stage the source and recipe changes in a same-repository PR. Do not edit the
   lock by hand or run a publishing job from the PR branch.
2. Review the candidate and its target coverage. From `main`, dispatch
   **Publish PR linker inputs** with that PR number. The trusted controller
   dispatches `linker-inputs.yml` at the exact PR head; candidate jobs build
   with `scripts/build_link_inputs.roc`, compare two independent outputs,
   assemble, and attest without release credentials.
3. The controller verifies the candidate evidence, publishes an immutable
   linker-input release, then adds only the new lock in a GitHub-signed commit
   to the PR. Review the release manifest, target archives, hashes, source SHA,
   and lock diff; rerun the PR checks on that new head before merging.

Rendered docs are ignored build output and deployed through Pages artifacts.
