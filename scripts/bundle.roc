#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout
import src/Bundle

## Bundle the platform from an explicit inventory in a clean staging directory;
## never glob local binaries. Run from the repository root after `zig build`.
##
##   scripts/bundle.roc                          the bundle, in the repository root
##   scripts/bundle.roc -- --output-dir DIR      the bundle, in DIR
##
## The bundle holds the platform's Roc modules, each target's host library,
## the locked linker inputs for each target, their licenses and sources, and
## the platform license. Its inventory, with every file's SHA-256, is written
## to `.zig-cache/platform-bundle.json` for the release SBOM. The last line
## printed is `Created: <absolute path>`.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	output = match args.map(OsStr.display) {
		[] => "."
		["--output-dir", directory] => directory
		_ => {
			_ = Stderr.line!("usage: scripts/bundle.roc [--output-dir DIR]")
			return Err(Exit(2))
		}
	}
	match run!(output) {
		Ok({}) => Ok({})
		Err(message) => {
			_ = Stderr.line!("error: ${message}")
			Err(Exit(1))
		}
	}
}

run! : Str => Try({}, Str)
run! = |output| {
	cwd = Env.cwd!().map_err(|_| "cannot read the working directory")?
	lock = Bundle.parse_lock(read!(Path.join(cwd, "link-inputs.lock.json"))?)?
	tree = Path.join(cwd, ".zig-cache/linker-inputs/${lock.sha256}/tree")
	# The locked inputs must be the verified ones; the host libraries must be built.
	succeed!("zig", ["build", "check-link-inputs"])?

	var $sources = []
	for file in names!(Path.join(cwd, "platform"))? {
		if file.ends_with(".roc") {
			$sources = $sources.append({ name: file, from: Path.join(cwd, "platform/${file}") })
		}
	}
	for target in Bundle.bundle_targets {
		host = Bundle.host_library(target)
		$sources = $sources.append({ name: "targets/${target}/${host}", from: Path.join(cwd, "platform/targets/${target}/${host}") })
		for item in names!(Path.join(tree, "targets/${Bundle.input_target(target)}"))? {
			$sources = $sources.append({ name: "targets/${target}/${item}", from: Path.join(cwd, "platform/targets/${target}/${item}") })
		}
	}
	for directory in ["licenses", "sources"] {
		for item in names!(Path.join(tree, directory))? {
			$sources = $sources.append({ name: "linker-inputs/${directory}/${item}", from: Path.join(tree, "${directory}/${item}") })
		}
	}
	$sources = $sources.append({ name: "linker-inputs/dependency.json", from: Path.join(tree, "dependency.json") })
	$sources = $sources.append({ name: "licenses/platform.txt", from: Path.join(cwd, "LICENSE") })
	sources = $sources.sort_with(|a, b| Bundle.compare(a.name, b.name))

	Path.create_all!(Path.join(cwd, ".zig-cache")).map_err(|_| "cannot create .zig-cache")?
	staging = Env.create_temp_dir_in!(Path.join(cwd, ".zig-cache"), "platform-bundle-").map_err(|_| "cannot create a staging directory")?
	for source in sources {
		match Path.type!(source.from) {
			Ok(IsFile) => {}
			_ => return Err("missing or invalid bundle input: ${Path.display(source.from)}; run zig build first")
		}
		destination = Path.join(staging, source.name)
		Path.create_all!(Path.unix(Bundle.parent(Path.display(destination)))).map_err(|_| "cannot stage ${source.name}")?
		bytes = Path.read_bytes!(source.from).map_err(|_| "cannot read ${Path.display(source.from)}")?
		Path.write_bytes!(destination, bytes).map_err(|_| "cannot stage ${source.name}")?
	}

	output_dir = Path.unix(Bundle.resolve(Path.display(cwd), output))
	Path.create_all!(output_dir).map_err(|_| "cannot create ${Path.display(output_dir)}")?
	files = sources.map(|source| source.name)
	ran = Cmd.new(OsStr.from_str("roc")).args(["bundle"].concat(files).concat(["--output-dir", Path.display(output_dir)]).map(OsStr.from_str)).cwd(staging).stdout(Capture).stderr(Capture).timeout_ms(600_000).output_limit(10_000_000).run!().map_err(|_| "roc bundle did not complete")?
	report = "${Str.from_utf8_lossy(ran.stdout_bytes)}${Str.from_utf8_lossy(ran.stderr_bytes)}"
	if ran.status != Exited(0) {
		Stderr.line!(report).map_err(|_| "cannot write to stderr")?
		return Err("roc bundle failed")
	}
	found = Bundle.created(report)
	if found.len() != 1 {
		return Err("expected exactly one created platform archive in:\n${report}")
	}
	created = found.first() ?? ""
	# Roc may print the archive relative to its working directory, the staging tree.
	archive_name = Bundle.file_name(created)
	archive = Path.join(output_dir, archive_name)
	if !(Path.is_file!(archive) ?? Bool.False) or Bundle.parent(Bundle.resolve(Path.display(staging), created)) != Path.display(output_dir) {
		return Err("unexpected platform archive path: ${created}")
	}

	digests = sha256!(staging, files)?
	inventory = Bundle.inventory(archive_name, (sha256!(output_dir, [archive_name])?).first() ?? "", lock, files, digests)
	Path.write_utf8!(Path.join(cwd, ".zig-cache/platform-bundle.json"), inventory).map_err(|_| "cannot write .zig-cache/platform-bundle.json")?
	_ = Path.delete_all!(staging)
	Stdout.line!(Bundle.without_created(report)).map_err(|_| "cannot write to stdout")?
	Stdout.line!("Created: ${Path.display(archive)}").map_err(|_| "cannot write to stdout")
}

read! : Path => Try(Str, Str)
read! = |path| Path.read_utf8!(path).map_err(|_| "cannot read ${Path.display(path)}")

## The names of the entries directly inside `directory`, sorted.
names! : Path => Try(List(Str), Str)
names! = |directory| {
	entries = Path.list!(directory).map_err(|_| "cannot list ${Path.display(directory)}")?
	Ok(entries.map(|entry| Bundle.file_name(Path.display(entry))).sort_with(Bundle.compare))
}

## The SHA-256 of each of `files`, relative to `directory`, in order.
sha256! : Path, List(Str) => Try(List(Str), Str)
sha256! = |directory, files| {
	ran = Cmd.new(OsStr.from_str("sha256sum")).args(["--"].concat(files).map(OsStr.from_str)).cwd(directory).stdout(Capture).stderr(Capture).timeout_ms(600_000).output_limit(10_000_000).run!().map_err(|_| "sha256sum did not complete")?
	if ran.status != Exited(0) {
		return Err("sha256sum failed in ${Path.display(directory)}")
	}
	Bundle.parse_sums(Str.from_utf8_lossy(ran.stdout_bytes), files)
}

## Print a command, then run it with inherited output; a non-zero exit is an error.
succeed! : Str, List(Str) => Try({}, Str)
succeed! = |program, args| {
	Stdout.line!("+ ${program} ${Str.join_with(args, " ")}").map_err(|_| "cannot write to stdout")?
	match Cmd.new_str(program).args_str(args).exec_exit_code!() {
		Ok(0) => Ok({})
		Ok(code) => Err("${program} ${Str.join_with(args, " ")} exited with code ${code.to_str()}")
		Err(_) => Err("could not run ${program}")
	}
}
