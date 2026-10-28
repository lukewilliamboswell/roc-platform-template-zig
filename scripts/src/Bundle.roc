## Pure decisions for bundling the platform: its targets, the locked linker
## inputs, the archive `roc bundle` reports, and the inventory the SBOM reads.
Bundle := [].{

	## The targets the platform bundle carries, in bundle order.
	bundle_targets : List(Str)
	bundle_targets = ["x64mac", "arm64mac", "x64win", "x64musl", "x64v1musl", "arm64musl", "arm64v1musl"]

	## The linker-input target a bundle target takes its files from: the
	## baseline musl targets share their musl inputs.
	input_target : Str -> Str
	input_target = |target|
		match target {
			"x64v1musl" => "x64musl"
			"arm64v1musl" => "arm64musl"
			_ => target
		}

	## The host library `zig build` writes for a target.
	host_library : Str -> Str
	host_library = |target| if (target.ends_with("win")) "host.lib" else "libhost.a"

	## The parts of `link-inputs.lock.json` a bundle and its SBOM name.
	Lock : { repository : Str, release : Str, asset : Str, sha256 : Str, size : U64, source_commit : Str, input_fingerprint : Str }

	parse_lock : Str -> Try(Lock, Str)
	parse_lock = |source| {
		parsed : Try({ schema_version : U64, kind : Str, repository : Str, release : Str, source : { sha : Str, input_fingerprint : Str }, inputs : { all : { asset : Str, sha256 : Str, size : U64 } } }, _)
		# `targets` is a reserved word, so the key is decoded under another name.
		parsed = Json.parse(source.replace_each("\"targets\":", "\"inputs\":"))
		lock = match parsed {
			Ok(value) => value
			Err(_) => return Err("invalid link-inputs.lock.json")
		}
		if lock.schema_version != 1 or lock.kind != "roc-zig-link-inputs" or !hex(lock.inputs.all.sha256, 64) or !hex(lock.source.sha, 40) or lock.release != "link-inputs-sha256-${lock.release.drop_prefix("link-inputs-sha256-")}" {
			return Err("invalid content-addressed linker-input lock")
		}
		Ok({ repository: lock.repository, release: lock.release, asset: lock.inputs.all.asset, sha256: lock.inputs.all.sha256, size: lock.inputs.all.size, source_commit: lock.source.sha, input_fingerprint: lock.source.input_fingerprint })
	}

	## The download location of the locked linker inputs.
	lock_url : Lock -> Str
	lock_url = |lock| "https://github.com/${lock.repository}/releases/download/${lock.release}/${lock.asset}"

	## Every archive a `roc bundle` report says it created.
	created : Str -> List(Str)
	created = |report| report.split_on("\n").map(|line| line.trim()).keep_if(|line| line.starts_with("Created:") and line.ends_with(".tar.zst")).map(|line| line.drop_prefix("Created:").trim())

	## The report with its `Created:` line removed; the script prints its own.
	without_created : Str -> Str
	without_created = |report| Str.join_with(report.split_on("\n").drop_if(|line| line.trim().starts_with("Created:")), "\n").trim()

	## `path` resolved against `directory` unless it is already absolute.
	resolve : Str, Str -> Str
	resolve = |directory, path| if (path.starts_with("/")) path else normalize("${directory}/${path}")

	parent : Str -> Str
	parent = |path| {
		parts = path.split_on("/")
		Str.join_with(parts.take_first(parts.len() - 1), "/")
	}

	file_name : Str -> Str
	file_name = |path| path.split_on("/").last() ?? path

	## `sha256sum` output for `files`, in the same order.
	parse_sums : Str, List(Str) -> Try(List(Str), Str)
	parse_sums = |output, files| {
		lines = output.split_on("\n").keep_if(|line| line != "")
		if lines.len() != files.len() {
			return Err("sha256sum reported ${lines.len().to_str()} digests for ${files.len().to_str()} files")
		}
		Ok(lines.map(|line| line.split_on(" ").first() ?? ""))
	}

	## The bundle inventory the release SBOM checks the archive against.
	inventory : Str, Str, Lock, List(Str), List(Str) -> Str
	inventory = |archive, sha256, lock, files, digests| {
		pairs = List.map2(files, digests, |name, digest| { name, sha256: digest })
		"${Json.to_str({ archive, sha256, linker_inputs: lock, files: pairs })}\n"
	}

	Inventory : { archive : Str, sha256 : Str, linker_inputs : Lock, files : List({ name : Str, sha256 : Str }) }

	parse_inventory : Str -> Try(Inventory, Str)
	parse_inventory = |source| {
		parsed : Try(Inventory, _)
		parsed = Json.parse(source)
		parsed.map_err(|_| "invalid .zig-cache/platform-bundle.json")
	}

	## Byte order, so listings are the same on every file system.
	compare : Str, Str -> [Before, Same, After]
	compare = |a, b| by_bytes(a.to_utf8(), b.to_utf8())
}

hex : Str, U64 -> Bool
hex = |value, length| value.to_utf8().len() == length and value.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))

# Remove `.` and `..` segments, as the archive path a report names may hold them.
normalize : Str -> Str
normalize = |path| {
	var $kept = []
	for part in path.split_on("/") {
		if part == ".." {
			$kept = $kept.drop_last(1)
		} else if part != "." {
			$kept = $kept.append(part)
		}
	}
	Str.join_with($kept, "/")
}

by_bytes : List(U8), List(U8) -> [Before, Same, After]
by_bytes = |a, b|
	match (a, b) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([x, .. as rest_a], [y, .. as rest_b]) => if (x < y) Before else if (x > y) After else by_bytes(rest_a, rest_b)
	}

expect Bundle.created("x\nCreated: ../../Abc.tar.zst\nCompressed size: 1\n") == ["../../Abc.tar.zst"]
expect Bundle.created("Created: /a/b/Abc.tar.zst") == ["/a/b/Abc.tar.zst"]
expect Bundle.resolve("/r/.zig-cache/platform-bundle-x", "../../Abc.tar.zst") == "/r/Abc.tar.zst"
expect Bundle.resolve("/r/s", "/out/Abc.tar.zst") == "/out/Abc.tar.zst"
expect Bundle.parent("/r/Abc.tar.zst") == "/r"
expect Bundle.input_target("x64v1musl") == "x64musl" and Bundle.input_target("x64win") == "x64win"
expect Bundle.host_library("x64win") == "host.lib" and Bundle.host_library("arm64mac") == "libhost.a"
expect Bundle.parse_sums("aa  one\nbb  two\n", ["one", "two"]) == Ok(["aa", "bb"])
expect Bundle.parse_sums("aa  one\n", ["one", "two"]).is_err()
expect Bundle.compare("B", "a") == Before and Bundle.compare("a", "a") == Same
expect Bundle.parse_lock("{}").is_err()
