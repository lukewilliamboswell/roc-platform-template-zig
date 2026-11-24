# Development environment and tasks for the Zig platform template, realised by roc-blueprint.
#
#     blueprint run check              # pins, policy, the scripts' tests and formatting
#     blueprint run fetch-link-inputs  # the locked linker inputs, before building from a fresh checkout
#     blueprint run test               # build the host, then check, build and run every example
#     blueprint run release-test -- test-examples --update   # record what the examples print in tests/spec.json
#     blueprint run bundle             # the platform bundle, in the repository root
#     blueprint run release-package -- build VERSION --platform-bundle DIR
#     blueprint run link-inputs        # build the linker-input release candidate (Linux)
#     blueprint shell                  # the development environment
#     blueprint update                 # refresh Blueprint.lock
#
# Two compilers are in play and are not interchangeable. `roc-stable` is the
# nightly named below; it runs the scripts under scripts/. Bare `roc` is the
# latest nightly, which the machine provides: the platform and its examples
# name no compiler.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.13.0/DBtzmMfrSgt6nCGVAcZYCVPxWbhpqw3MXpm6sdQzMn4v.tar.zst" }

import pf.Recipes

config = [
	Name("roc-platform-template-zig"),
	Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin", "x86_64-darwin", "x86_64-windows"]),
	Environment(
		"scripts",
		[
			Programs([Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-11-23-b5c77fc"))]),
			# Every bundle the scripts depend on, including dependencies of
			# dependencies: `roc-stable deps scripts/check_all.roc` lists them.
			RocPackages([
				"https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
				"https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
			]),
			Expect(["git"]),
		],
	),
	Environment(
		"dev",
		[
			Extend("scripts"),
			# The exact Zig release that builds the host; build.zig.zon and
			# runtime/sources.json name the same version. The Zig-listed mirror
			# serves the same checksum-locked archives as ziglang.org.
			Programs([
				Fetch(
					"zig",
					|system| match system {
						"x86_64-linux" => Mirrored(Archive("https://pkg.hexops.org/zig/zig-x86_64-linux-0.17.0.tar.xz", TarXz, "zig-x86_64-linux-0.17.0/zig"), ["https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz"])
						"aarch64-linux" => Mirrored(Archive("https://pkg.hexops.org/zig/zig-aarch64-linux-0.17.0.tar.xz", TarXz, "zig-aarch64-linux-0.17.0/zig"), ["https://ziglang.org/download/0.17.0/zig-aarch64-linux-0.17.0.tar.xz"])
						"aarch64-darwin" => Mirrored(Archive("https://pkg.hexops.org/zig/zig-aarch64-macos-0.17.0.tar.xz", TarXz, "zig-aarch64-macos-0.17.0/zig"), ["https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz"])
						"x86_64-darwin" => Mirrored(Archive("https://pkg.hexops.org/zig/zig-x86_64-macos-0.17.0.tar.xz", TarXz, "zig-x86_64-macos-0.17.0/zig"), ["https://ziglang.org/download/0.17.0/zig-x86_64-macos-0.17.0.tar.xz"])
						"x86_64-windows" => Mirrored(Archive("https://pkg.hexops.org/zig/zig-x86_64-windows-0.17.0.zip", Zip, "zig-x86_64-windows-0.17.0/zig.exe"), ["https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip"])
						_ => Unavailable
					},
				),
			]),
			Expect(["roc", "sha256sum", "tar", "gzip", "zip", "unzip", "gh"]),
		],
	),
	Environment(
		"docs",
		[
			Programs([
				Fetch(
					"roc-docs",
					|system| match system {
						"x86_64-darwin" | "x86_64-windows" => Unavailable
						_ => Recipes.file("https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-0.11.1/roc-docs-{system}")(system)
					},
				),
			]),
			Expect(["roc"]),
		],
	),
	Task("docs", [Use("docs"), Run(["roc-docs", "build", "--workspace", ".", "--pdf-filename", "roc-platform-template-zig.pdf", "--site-url", "https://lukewilliamboswell.github.io/roc-platform-template-zig/", "--api-entrypoint", "platform/main.roc"])]),
	Task("docs-manual", [Use("docs"), Run(["roc-docs", "build", "--workspace", ".", "--pdf-filename", "roc-platform-template-zig.pdf", "--site-url", "https://lukewilliamboswell.github.io/roc-platform-template-zig/"])]),
	Shell("default", [Use("dev")]),
	Task("check", [Use("dev"), Run(["roc-stable", "scripts/check_all.roc"])]),
	Task("pins", [Use("scripts"), Run(["roc-stable", "scripts/check_no_pins.roc"])]),
	# The locked linker inputs, downloaded once and verified on every use.
	Task("fetch-link-inputs", [Use("dev"), Run(["zig", "build", "fetch-link-inputs"])]),
	# The host as a release ships it.
	Task("build-release", [Use("dev"), Run(["zig", "build", "-Doptimize=ReleaseSafe"])]),
	Task("test", [Use("dev"), Run(["zig", "build", "test"])]),
	Task("bundle", [Use("dev"), Run(["roc-stable", "scripts/bundle.roc"])]),
	Environment("release-test", [Programs([Fetch("release-package", release_package)]), Expect(["roc"])]),
	Environment("release", [Extend("dev"), Programs([Fetch("release-package", release_package)])]),
	Task("release-package", [Use("release"), Run(["release-package"])]),
	Task("release-test", [Use("release-test"), Run(["release-package"])]),
	Task("sbom", [Use("dev"), Run(["roc-stable", "scripts/sbom.roc"])]),
	Task("test-expects", [Use("dev"), Run(["roc-stable", "scripts/test_expects.roc"])]),
	Task("test-host", [Use("dev"), Run(["zig", "build", "test-host", "-Doptimize=ReleaseSafe"])]),
	Task("link-inputs", [Use("scripts"), Run(["roc-stable", "scripts/build_link_inputs.roc"])]),
	# The tooling compiler, as release notes record it.
	Task("compiler-version", [Use("scripts"), Run(["roc-stable", "version"])]),
	Task("json-value-tests", [Use("scripts"), Run(["roc-stable", "test", "scripts/src/JsonValue.roc"])]),
	Task("link-input-tests", [Use("scripts"), Run(["roc-stable", "test", "scripts/src/LinkInputs.roc"])]),
]

release_package = Recipes.file("https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-0.11.1/release-package-{system}")
