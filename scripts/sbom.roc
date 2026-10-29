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
import src/Sbom
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	match run!(args) {
		Ok({}) => Ok({})
		Err(message) => {
			_ = Stderr.line!(message)
			Err(Exit(1))
		}
	}
}

run! : List(OsStr) => Try({}, Str)
run! = |args| {
	if !args.is_empty() {
		return Err("usage: scripts/sbom.roc")
	}
	root = Env.cwd!().map_err(|_| "cannot read working directory")?
	inventory = Bundle.parse_inventory(read!(Path.join(root, ".zig-cache/platform-bundle.json"))?)?
	_ = capture!(["zig", "build", "check-link-inputs"], root)?
	sbom!(root, inventory, Path.join(root, "dist/platform.spdx.json"))
}

name = "roc-platform-template-zig"

dist = "dist"

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
	document = Sbom.sbom({
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
