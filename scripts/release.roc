#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst",
	roc: "nightly-2026-10-09-258ab27",
}

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout
import src/Bundle
import src/Compatibility
import src/Examples
import src/Release

## Build and test what a platform release publishes. Run from the repository
## root after `zig build`.
##
##   scripts/release.roc -- build VERSION   dist/: the bundle, the examples archive, the SBOM and SHA256SUMS
##   scripts/release.roc -- test-archive    the examples archive in dist/, unchanged, against the bundle in dist/
##
## VERSION is `MAJOR.MINOR.PATCH`, or `0.0.1-dryrun` for a pull request. The
## archive's examples name the bundle by the URL this release will publish it
## at; `test-archive` serves the bundle from a loopback address in its place,
## with an empty package cache, so the bytes tested are the bytes published.
## `GITHUB_REPOSITORY` names the repository the URLs point at.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["build", version] => build!(version)
		["test-archive"] => test_archive!({})
		_ => {
			_ = Stderr.line!("usage: scripts/release.roc build VERSION | test-archive")
			return Err(Exit(2))
		}
	}
	match result {
		Ok({}) => Ok({})
		Err(message) => {
			_ = Stderr.line!("error: ${message}")
			Err(Exit(1))
		}
	}
}

name = "roc-platform-template-zig"

dist = "dist"

build! : Str => Try({}, Str)
build! = |version| {
	if !Release.valid_version(version) {
		return Err("${version} is not MAJOR.MINOR.PATCH or ${Release.dry_run}")
	}
	cwd = Env.cwd!().map_err(|_| "cannot read the working directory")?
	output = Path.join(cwd, dist)
	if Path.exists!(output) ?? Bool.False {
		return Err("${dist}/ exists already; start from an empty output directory")
	}
	repository = repository!({})
	suite = Compatibility.working_tree_suite(read!(Path.join(cwd, "tests/spec.json"))?)?

	say!("\n== Bundle")?
	succeed!("roc-stable", ["scripts/bundle.roc", "--", "--output-dir", dist])?
	inventory = Bundle.parse_inventory(read!(Path.join(cwd, ".zig-cache/platform-bundle.json"))?)?
	url = Release.bundle_url(repository, version, inventory.archive)

	say!("\n== Examples archive")?
	root = Release.examples_archive(name, version).drop_suffix(".zip")
	stage = Env.create_temp_dir_in!(Path.join(cwd, ".zig-cache"), "release-").map_err(|_| "cannot create a staging directory")?
	var $entries = []
	for file in tracked!("examples")? {
		source = Path.read_bytes!(Path.join(cwd, file)).map_err(|_| "cannot read ${file}")?
		bytes = if (file.ends_with("/main.roc")) Str.to_utf8(Release.with_platform(Str.from_utf8_lossy(source), url).map_err(|problem| "${file} ${problem}")?) else source
		write_bytes!(stage, "${root}/${file}", bytes)?
		$entries = $entries.append("${root}/${file}")
	}
	write_bytes!(stage, "${root}/spec.json", Str.to_utf8(Compatibility.published(suite, version, [url])))?
	write_bytes!(stage, "${root}/README.md", Str.to_utf8(Release.readme(name, version, url)))?
	entries = ["${root}/README.md", "${root}/spec.json"].concat($entries)
	zip!(stage, entries, Path.join(output, Release.examples_archive(name, version)))?

	say!("\n== SBOM")?
	sbom!(cwd, inventory, Path.join(output, "platform.spdx.json"))?

	say!("\n== Checksums")?
	sums = capture!(["sha256sum", "--"].concat(names!(output)?), output)?
	Path.write_utf8!(Path.join(output, "SHA256SUMS"), sums).map_err(|_| "cannot write SHA256SUMS")?
	_ = Path.delete_all!(stage)
	say!(sums)?
	test_archive!({})
}

## The platform's SPDX document, checked against the bundle inventory and the
## verified linker inputs it names.
sbom! : Path, Bundle.Inventory, Path => Try({}, Str)
sbom! = |cwd, inventory, destination| {
	lock = Bundle.parse_lock(read!(Path.join(cwd, "link-inputs.lock.json"))?)?
	if inventory.linker_inputs != lock {
		return Err("the bundle inventory names other linker inputs than link-inputs.lock.json")
	}
	archive_sha256 = (sha256!(Path.join(cwd, dist), [inventory.archive])?).first() ?? ""
	if archive_sha256 != inventory.sha256 {
		return Err("${dist}/${inventory.archive} is not the bundle the inventory describes")
	}
	tree = Path.join(cwd, ".zig-cache/linker-inputs/${lock.sha256}/tree")
	manifest : Try({ version : Str }, _)
	manifest = Json.parse(read!(Path.join(tree, "dependency.json"))?)
	inputs_version = (manifest.map_err(|_| "invalid linker-input dependency.json")?).version
	input_names = files_under!(tree, "")?.drop_if(|file| file == "dependency.json")
	input_digests = sha256!(tree, input_names)?
	commit = capture!(["git", "rev-parse", "HEAD"], cwd)?.trim()
	epoch = capture!(["git", "show", "-s", "--format=%ct", "HEAD"], cwd)?.trim()
	created = capture!(["date", "-u", "-d", "@${epoch}", "+%Y-%m-%dT%H:%M:%SZ"], cwd)?.trim()
	zig = capture!(["zig", "version"], cwd)?.trim()
	roc = capture!(["roc", "version"], cwd)?.trim().drop_prefix("Roc compiler version ")
	document = Release.sbom({
		name,
		commit,
		created,
		archive_sha256,
		inputs: { version: inputs_version, url: Bundle.lock_url(lock), sha256: lock.sha256, files: List.map2(input_names, input_digests, |file, sha256| { name: file, sha256 }) },
		platform_files: inventory.files,
		zig,
		roc,
	})
	Path.write_utf8!(destination, document).map_err(|_| "cannot write ${Path.display(destination)}")
}

## The examples archive in dist/, exactly as it would be published, against
## the bundle in dist/, served from a loopback address in place of its URL.
test_archive! : {} => Try({}, Str)
test_archive! = |{}| {
	cwd = Env.cwd!().map_err(|_| "cannot read the working directory")?
	output = Path.join(cwd, dist)
	files = names!(output)?
	bundle = match files.keep_if(|file| file.ends_with(".tar.zst")) {
		[one] => one
		_ => return Err("expected exactly one bundle in ${dist}/")
	}
	archive = match files.keep_if(|file| file.starts_with("${name}-examples-") and file.ends_with(".zip")) {
		[one] => one
		_ => return Err("expected exactly one examples archive in ${dist}/")
	}
	root = archive.drop_suffix(".zip")
	version = root.drop_prefix("${name}-examples-")
	repository = repository!({})
	url = Release.bundle_url(repository, version, bundle)

	Path.create_all!(Path.join(cwd, ".zig-cache")).map_err(|_| "cannot create .zig-cache")?
	temporary = Env.create_temp_dir_in!(Path.join(cwd, ".zig-cache"), "archive-test-").map_err(|_| "cannot create a temporary directory")?
	unpacked = Path.join(temporary, "unpacked")
	Path.create_all!(unpacked).map_err(|_| "cannot create ${Path.display(unpacked)}")?
	windows = Env.platform!().os == WINDOWS
	# Windows runners have no unzip; their bsdtar reads ZIP archives.
	unpack = if (windows) ["tar", "-xf", Path.display(Path.join(output, archive)), "-C", Path.display(unpacked)] else ["unzip", "-q", Path.display(Path.join(output, archive)), "-d", Path.display(unpacked)]
	_ = capture!(unpack, cwd)?
	suite_root = Path.join(unpacked, root)
	suite = Compatibility.published_suite(read!(Path.join(suite_root, "spec.json"))?, repository, version)?
	if suite.dependencies != [url] {
		return Err("the archived examples depend on ${Str.inspect(suite.dependencies)}, not on ${url}")
	}
	# An empty package cache makes Roc fetch the bundle from the loopback
	# server, as it would fetch the published bundle for a first user.
	records = Path.join(temporary, "records")
	cache = Path.join(temporary, "cache")
	Path.create_all!(cache).map_err(|_| "cannot create ${Path.display(cache)}")?
	say!("\n== Archived examples against ${bundle}, served in place of ${url}")?
	Path.create_all!(records).map_err(|_| "cannot create ${Path.display(records)}")?
	outcome = Examples.execute!({
		compiler: "roc",
		root: suite_root,
		suite,
		dependencies: [url],
		setup: { directory: records, cache, environment: [], environment_text: "[]" },
		case_timeout_ms: 10_000,
		source: Served([{ url, bundle: Path.join(output, bundle) }]),
		mode: Compare,
		first_number: 1,
	})?
	match outcome.interrupted {
		None => {}
		Timeout(number) => return Err("command ${number.to_str()} timed out; see ${Path.display(records)}")
		OutputLimit(number) => return Err("command ${number.to_str()} exceeded the output limit; see ${Path.display(records)}")
	}
	for failure in outcome.failures {
		_ = Stderr.line!("FAIL ${failure}")
	}
	if outcome.failed > 0 {
		return Err("${outcome.failed.to_str()} of the archived examples or cases failed; records are in ${Path.display(records)}")
	}
	say!("All archived examples passed (${outcome.tested.to_str()} cases, ${outcome.skipped.to_str()} skipped)")
}

repository! : {} => Str
repository! = |{}| Env.var_str!(OsStr.from_str("GITHUB_REPOSITORY")) ?? "lukewilliamboswell/roc-platform-template-zig"

## The regular files Git tracks under `directory`, by path.
tracked! : Str => Try(List(Str), Str)
tracked! = |directory| {
	cwd = Env.cwd!().map_err(|_| "cannot read the working directory")?
	listing = capture!(["git", "ls-files", "--", directory], cwd)?
	Ok(listing.split_on("\n").keep_if(|line| line != "").sort_with(Bundle.compare))
}

## Every regular file under `directory`, relative to it, sorted.
files_under! : Path, Str => Try(List(Str), Str)
files_under! = |directory, prefix| {
	var $found = []
	for entry in Path.list!(directory).map_err(|_| "cannot list ${Path.display(directory)}")? {
		file = Bundle.file_name(Path.display(entry))
		relative = if (prefix == "") file else "${prefix}/${file}"
		match Path.type!(entry).map_err(|_| "cannot inspect ${Path.display(entry)}")? {
			IsFile => {
				$found = $found.append(relative)
			}
			IsDir => {
				$found = $found.concat(files_under!(entry, relative)?)
			}
			_ => return Err("${Path.display(entry)} is not a regular file or directory")
		}
	}
	Ok($found.sort_with(Bundle.compare))
}

names! : Path => Try(List(Str), Str)
names! = |directory| {
	entries = Path.list!(directory).map_err(|_| "cannot list ${Path.display(directory)}")?
	Ok(entries.map(|entry| Bundle.file_name(Path.display(entry))).sort_with(Bundle.compare))
}

write_bytes! : Path, Str, List(U8) => Try({}, Str)
write_bytes! = |stage, relative, bytes| {
	destination = Path.join(stage, relative)
	Path.create_all!(Path.unix(Bundle.parent(Path.display(destination)))).map_err(|_| "cannot stage ${relative}")?
	Path.write_bytes!(destination, bytes).map_err(|_| "cannot stage ${relative}")
}

## Add `entries`, relative to `stage`, to the ZIP `archive`, with fixed times
## and modes so that packing the same files twice gives the same bytes.
zip! : Path, List(Str), Path => Try({}, Str)
zip! = |stage, entries, archive| {
	staged = entries.map(|entry| Path.display(Path.join(stage, entry)))
	_ = capture!(["chmod", "0644"].concat(staged), stage)?
	_ = capture!(["env", "TZ=UTC", "touch", "-t", "198001010000"].concat(staged), stage)?
	# -X leaves out owner and timestamp extras, -D directory entries; -@ reads
	# the entries to add from standard input.
	ran = Cmd.new(OsStr.from_str("env")).args(["TZ=UTC", "zip", "-q", "-X", "-D", Path.display(archive), "-@"].map(OsStr.from_str)).cwd(stage).stdin(Bytes(Str.to_utf8(Str.join_with(entries, "\n")))).stdout(Capture).stderr(Capture).timeout_ms(600_000).output_limit(10_000_000).run!().map_err(|_| "zip did not complete")?
	if ran.status != Exited(0) {
		return Err("zip failed for ${Path.display(archive)}: ${Str.from_utf8_lossy(ran.stderr_bytes)}")
	}
	say!("Created: ${Path.display(archive)}")
}

sha256! : Path, List(Str) => Try(List(Str), Str)
sha256! = |directory, files| Bundle.parse_sums(capture!(["sha256sum", "--"].concat(files), directory)?, files)

## Run a command to completion and return its standard output; a non-zero
## exit is an error that shows its standard error.
capture! : List(Str), Path => Try(Str, Str)
capture! = |argv, cwd|
	match argv {
		[program, .. as arguments] => {
			ran = Cmd.new(OsStr.from_str(program)).args(arguments.map(OsStr.from_str)).cwd(cwd).stdout(Capture).stderr(Capture).timeout_ms(600_000).output_limit(50_000_000).run!().map_err(|_| "${program} did not complete")?
			if ran.status != Exited(0) {
				return Err("${Str.join_with(argv, " ")} failed: ${Str.from_utf8_lossy(ran.stderr_bytes)}")
			}
			Ok(Str.from_utf8_lossy(ran.stdout_bytes))
		}
		[] => Err("no command")
	}

read! : Path => Try(Str, Str)
read! = |path| Path.read_utf8!(path).map_err(|_| "cannot read ${Path.display(path)}")

say! : Str => Try({}, Str)
say! = |line| Stdout.line!(line).map_err(|_| "cannot write to stdout")

## Print a command, then run it with inherited output; a non-zero exit is an error.
succeed! : Str, List(Str) => Try({}, Str)
succeed! = |program, args| {
	say!("+ ${program} ${Str.join_with(args, " ")}")?
	match Cmd.new_str(program).args_str(args).exec_exit_code!() {
		Ok(0) => Ok({})
		Ok(code) => Err("${program} ${Str.join_with(args, " ")} exited with code ${code.to_str()}")
		Err(_) => Err("could not run ${program}")
	}
}
