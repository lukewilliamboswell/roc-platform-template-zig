# Development environment and tasks for the Zig platform template, realised by roc-blueprint.
#
#     blueprint run check              # pins, policy, the scripts' tests and formatting
#     blueprint run fetch-link-inputs  # the locked linker inputs, before building from a fresh checkout
#     blueprint run test               # build the host, then check, build and run every example
#     blueprint run test -- --update   # record what the examples print in tests/spec.json
#     blueprint run bundle             # the platform bundle, in the repository root
#     blueprint run release -- build VERSION  # dist/: bundle, examples archive and SBOM, tested over loopback
#     blueprint run link-inputs        # build the linker-input release candidate (Linux)
#     blueprint shell                  # the development environment
#     blueprint update                 # refresh Blueprint.lock
#
# Two compilers are in play and are not interchangeable. `roc-stable` is the
# nightly named below; it runs the scripts under scripts/. Bare `roc` is the
# latest nightly, which the machine provides: the platform and its examples
# name no compiler.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.8.0/FbJymjYdCxx9vqMcau7r4tQfeAbnVGqqJoYrLGqPCqKu.tar.zst" }

import pf.Recipes

config = [
	Name("roc-platform-template-zig"),
	Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin"]),
	Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),
	Environment(
		"scripts",
		[
			Programs([Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-09-258ab27"))]),
			# Every bundle the scripts depend on, including dependencies of
			# dependencies: `roc-stable deps scripts/check_all.roc` lists them.
			RocPackages([
				"https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst",
			]),
			Expect(["roc", "git"]),
		],
	),
	Environment(
		"dev",
		[
			Extend("scripts"),
			# The exact Zig release that builds the host; build.zig.zon and
			# runtime/sources.json name the same version.
			Tools(["nix#zig_0_17", "nix#coreutils", "nix#gnutar", "nix#gzip", "nix#zip", "nix#unzip", "nix#gh"]),
		],
	),
	Environment("docs", [Programs([Fetch("roc-docs", Recipes.file("https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-0.4.0/roc-docs-{system}"))]), Expect(["roc"])]),
	Task("docs", [Use("docs"), Run(["roc-docs", "build", "--workspace", ".", "--pdf-filename", "roc-platform-template-zig.pdf", "--site-url", "https://lukewilliamboswell.github.io/roc-platform-template-zig/", "--api-entrypoint", "platform/main.roc"])]),
	Shell("default", [Use("dev")]),
	Task("check", [Use("dev"), Run(["scripts/check_all.roc"])]),
	Task("pins", [Use("scripts"), Run(["scripts/check_no_pins.roc"])]),
	# The locked linker inputs, downloaded once and verified on every use.
	Task("fetch-link-inputs", [Use("dev"), Run(["zig", "build", "fetch-link-inputs"])]),
	# The host as a release ships it.
	Task("build-release", [Use("dev"), Run(["zig", "build", "-Doptimize=ReleaseSafe"])]),
	Task("test", [Use("dev"), Run(["scripts/test_examples.roc", "--"])]),
	Task("bundle", [Use("dev"), Run(["scripts/bundle.roc", "--"])]),
	Task("release", [Use("dev"), Run(["scripts/release.roc", "--"])]),
	Task("link-inputs", [Use("dev"), Run(["scripts/build_link_inputs.roc", "--"])]),
	# The tooling compiler, as release notes record it.
	Task("compiler-version", [Use("scripts"), Run(["roc-stable", "version"])]),
]
