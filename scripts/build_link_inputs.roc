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
import src/JsonValue
import src/LinkInputs

## Build the deterministic, independently released external linker inputs on
## x86-64 or ARM64 Linux, from a Zig distribution checked against its locked
## SHA-256 and minisign signature. Run from the repository root.
##
##   scripts/build_link_inputs.roc -- runtime --output DIR
##       the Linux musl runtime archive, its SPDX SBOM and SHA256SUMS
##   scripts/build_link_inputs.roc -- runtime-smoke ARCHIVE
##       link and run `runtime/smoke.c` against a runtime archive alone
##   scripts/build_link_inputs.roc -- build --output DIR
##       the aggregate linker-input archive, its SBOM, SHA256SUMS and the
##       release `dependency.json`
##   scripts/build_link_inputs.roc -- release --source DIR --output DIR
##       repackage the tested aggregate archive in DIR as `link-inputs-all.tar`
##       with `build-input-release.json` for the trusted publisher; reads
##       GITHUB_REPOSITORY, GITHUB_SHA and GITHUB_REF
##
## Every archive is a GNU tar ustar file of regular files only, sorted by name,
## with fixed owners, modes and times, compressed by `gzip -n`. Two runs from
## the same commit produce the same bytes. Needs `curl`, `minisign`, GNU `tar`,
## `xz`, `gzip`, `taskset`, `git` and the `llvm-objcopy`/`llvm-nm` that
## `runtime/sources.json` locks.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |raw| {
	args = match raw.map(OsStr.display) {
		["--", .. as rest] => rest
		other => other
	}
	match dispatch!(args) {
		Ok({}) => Ok({})
		Err(Usage) => {
			_ = Stderr.line!(usage)
			Err(Exit(2))
		}
		Err(Failed(message)) => {
			_ = Stderr.line!("error: ${message}")
			Err(Exit(1))
		}
	}
}

usage = "usage: scripts/build_link_inputs.roc -- {runtime --output DIR | runtime-smoke ARCHIVE | build --output DIR | release --source DIR --output DIR}"

dispatch! : List(Str) => Try({}, [Usage, Failed(Str)])
dispatch! = |args| {
	root = Path.display(Env.cwd!().map_err(|_| Failed("cannot read the working directory"))?)
	failed = |result| result.map_err(|message| Failed(message))
	if !(Path.is_file!(Path.unix("${root}/linker-inputs/sources.json")) ?? Bool.False) {
		return Err(Failed("run from the repository root"))
	}
	match args {
		["runtime", "--output", output] => failed(runtime!(root, LinkInputs.absolute(root, output)))
		["runtime-smoke", archive] => failed(smoke!(root, LinkInputs.absolute(root, archive)))
		["build", "--output", output] => failed(build!(root, LinkInputs.absolute(root, output)))
		["release", "--source", source, "--output", output] => failed(release!(root, LinkInputs.absolute(root, source), LinkInputs.absolute(root, output)))
		_ => Err(Usage)
	}
}

# ---------------------------------------------------------------- runtime

runtime! : Str, Str => Try({}, Str)
runtime! = |root, output| {
	lock = json!("${root}/runtime/sources.json")?
	check_objcopy!(lock)?
	new_directory!(output)?
	in_work!(
		root,
		"runtime-build-",
		|work| {
			zig = toolchain!(work, lock)?
			build_runtime!(root, lock, zig, work, output)
		},
	)
}

## Build the runtime from the verified `zig` in a fresh `work` directory.
build_runtime! : Str, JsonValue, Str, Str, Str => Try(Str, Str)
build_runtime! = |root, lock, zig, work, output| {
	objcopy = JsonValue.get_text(JsonValue.get(lock, "objcopy")?, "command")?
	cache = "${work}/cache"
	environment = [("ZIG_GLOBAL_CACHE_DIR", cache), ("ZIG_LOCAL_CACHE_DIR", "${work}/local")]
	stage = "${work}/stage"
	cpu = JsonValue.get_text(lock, "cpu")?
	optimization = JsonValue.get_text(lock, "optimization")?
	var $commands = []
	for field in JsonValue.fields(JsonValue.get(lock, "targets")?)? {
		name = field.key
		target = match field.value {
			Text(t) => t
			_ => return Err("runtime target ${name} must be a string")
		}
		target_out = "${stage}/targets/${name}"
		create_all!(target_out)?
		# stdin has stable contents and no absolute source path. -g0 avoids debug paths.
		flags = ["cc", "-target", target, "-mcpu=${cpu}", "-static", optimization, "-g0"]
		# Zig numbers a local `__anon_N` symbol by the compiler thread that made
		# it, so the libraries it compiles differ between runs unless it has one
		# thread. `zig cc` takes no job limit; one CPU gives it one thread.
		say!("Building the ${name} runtime on one CPU")?
		ran = exec!(
			tool("taskset", ["-c", "0", zig].concat(flags).concat(["-x", "c", "-", "-o", "${work}/probe-${name}", "-v"]), work).envs_str(environment).stdin(Bytes(Str.to_utf8(probe_main))),
			"zig cc for ${name}",
		)?
		$commands = $commands.append({ target: name, argv: ["zig"].concat(flags).concat(["-x", "c", "-", "-o", "probe", "-v"]) })
		for input in LinkInputs.runtime_link_inputs(Str.from_utf8_lossy(ran.stderr), cache)? {
			if !is_file!(input.path) {
				return Err("Unexpected runtime linker input: ${input.path}")
			}
			destination = "${target_out}/${input.name}"
			if input.name.ends_with(".a") {
				objects = "${work}/objects-${name}-${input.name}"
				create_all!(objects)?
				normalize_archive!(zig, objcopy, input.path, destination, objects)?
			} else {
				_ = exec!(tool(objcopy, ["--strip-debug", input.path, destination], work), "${objcopy} ${input.name}")?
			}
		}
	}
	zig_home = directory_of(zig)
	copy!("${zig_home}/LICENSE", "${stage}/licenses/Zig.txt")?
	copy!("${zig_home}/lib/libc/musl/COPYRIGHT", "${stage}/licenses/musl.txt")?
	version = JsonValue.get_text(lock, "runtime_version")?
	commit = git_commit!(root)?
	epoch = git_epoch!(root)?
	builder = "${machine!()?}-linux"
	var $files = []
	for name in LinkInputs.runtime_payload {
		$files = $files.append({ name, sha256: LinkInputs.sha256(read_bytes!("${stage}/${name}")?) })
	}
	manifest = JsonValue.render(LinkInputs.runtime_manifest({ version, commit, lock, commands: $commands, builder, files: $files }))
	write_text!("${stage}/manifest.json", manifest)?
	validate_runtime!(stage)?
	archive_name = "roc-runtime-${version}.tar.gz"
	archive = "${output}/${archive_name}"
	write_archive!(stage, LinkInputs.runtime_members, archive, Gzip)?
	archive_sha256 = LinkInputs.sha256(read_bytes!(archive)?)
	sbom = LinkInputs.runtime_sbom({ version, lock, builder, files: $files.append({ name: "manifest.json", sha256: LinkInputs.sha256(Str.to_utf8(manifest)) }), archive_sha256, epoch })?
	sbom_text = JsonValue.render(sbom)
	write_text!("${output}/runtime.spdx.json", sbom_text)?
	write_text!("${output}/SHA256SUMS", LinkInputs.sha256sums([{ name: archive_name, sha256: archive_sha256 }, { name: "runtime.spdx.json", sha256: LinkInputs.sha256(Str.to_utf8(sbom_text)) }]))?
	say!("Built ${archive}: ${archive_sha256}")?
	Ok(archive)
}

probe_main = "int main(void) { return 0; }\n"

## Zig's archives contain cache paths; rebuild one with stable member names
## and objects stripped of debug information.
normalize_archive! : Str, Str, Str, Str, Str => Try({}, Str)
normalize_archive! = |zig, objcopy, source, destination, work| {
	listed = exec!(tool(zig, ["ar", "t", source], work), "zig ar t ${source}")?
	var $objects = []
	for (member, index) in lines(listed.stdout).map_with_index(|member, index| (member, index)) {
		# Inputs are compiler output in our isolated cache, never downloaded code.
		number = Str.repeat("0", 4 - Str.count_utf8_bytes(index.to_str())).concat(index.to_str())
		object = "${work}/${number}.o"
		stripped = "${work}/stripped-${number}.o"
		extracted = exec!(tool(zig, ["ar", "pP", source, member], work), "zig ar p ${member}")?
		write_bytes!(object, extracted.stdout)?
		_ = exec!(tool(objcopy, ["--strip-debug", object, stripped], work), "${objcopy} ${member}")?
		$objects = $objects.append(stripped)
	}
	_ = exec!(tool(zig, ["ar", "rcsD", destination].concat($objects), work), "zig ar rcsD ${destination}")?
	Ok({})
}

## Check a runtime tree holds exactly the files its manifest lists, unchanged.
validate_runtime! : Str => Try({}, Str)
validate_runtime! = |directory| {
	inventory = LinkInputs.runtime_inventory(read_text!("${directory}/manifest.json")?)?
	if JsonValue.sort(walk!(directory, "")?) != LinkInputs.runtime_members {
		return Err("Unexpected runtime contents")
	}
	for file in inventory {
		if LinkInputs.sha256(read_bytes!("${directory}/${file.name}")?) != file.sha256 {
			return Err("Runtime file hash mismatch: ${file.name}")
		}
	}
	Ok({})
}

smoke! : Str, Str => Try({}, Str)
smoke! = |root, archive| {
	lock = json!("${root}/runtime/sources.json")?
	in_work!(
		root,
		"runtime-smoke-",
		|work| {
			zig = toolchain!(work, lock)?
			stage = "${work}/runtime"
			extract_runtime!(archive, stage, LinkInputs.runtime_members)?
			validate_runtime!(stage)?
			name = match machine!()? {
				"x86_64" => "x64musl"
				_ => "arm64musl"
			}
			target = JsonValue.get_text(JsonValue.get(lock, "targets")?, name)?
			object = "${work}/smoke.o"
			binary = "${work}/smoke"
			libs = "${stage}/targets/${name}"
			_ = exec!(loud(tool(zig, ["cc", "-target", target, "-mcpu=baseline", "-O2", "-UNDEBUG", "-c", "${root}/runtime/smoke.c", "-o", object], work)), "zig cc runtime/smoke.c")?
			# Direct LLD invocation ensures there is no implicit host/toolchain libc.
			_ = exec!(loud(tool(zig, ["ld.lld", "-static", "-o", binary, "${libs}/crt1.o", object, "--start-group"].concat(LinkInputs.runtime_files.drop_first(1).map(|file| "${libs}/${file}")).append("--end-group"), work)), "zig ld.lld")?
			_ = exec!(loud(tool(binary, [], work)), "the runtime smoke test")?
			say!("Runtime smoke test passed: ${archive}")
		},
	)
}

## Extract exactly `members` of a runtime archive after checking its listing.
extract_runtime! : Str, Str, List(Str) => Try({}, Str)
extract_runtime! = |archive, destination, members| {
	listing = exec!(tool("tar", ["-tvzf", archive], "/"), "tar -tv ${archive}")?
	LinkInputs.runtime_listing(Str.from_utf8_lossy(listing.stdout))?
	create_all!(destination)?
	_ = exec!(tool("tar", ["-xzf", archive, "-C", destination, "--no-same-owner", "--no-same-permissions", "--"].concat(members), "/"), "tar -x ${archive}")?
	Ok({})
}

# ---------------------------------------------------------------- aggregate

build! : Str, Str => Try({}, Str)
build! = |root, output| {
	sources = json!("${root}/linker-inputs/sources.json")?
	runtime_sources = json!("${root}/runtime/sources.json")?
	if !LinkInputs.valid_windows_header(read_text!("${root}/platform/main.roc")?) {
		return Err("platform/main.roc must list host.lib, app, then exactly the released Windows inputs for x64win")
	}
	catalog = json!("${root}/linker-inputs/macos-interfaces/libSystem.json")?
	stub = LinkInputs.macos_stub(catalog)?
	check_objcopy!(runtime_sources)?
	new_directory!(output)?
	in_work!(root, "linker-inputs-", |work| build_inputs!(root, output, work, sources, runtime_sources, catalog, stub))
}

build_inputs! : Str, Str, Str, JsonValue, JsonValue, JsonValue, Str => Try({}, Str)
build_inputs! = |root, output, work, sources, runtime_sources, catalog, stub| {
	create_all!("${work}/toolchain-download")?
	zig = toolchain!("${work}/toolchain-download", runtime_sources)?
	create_all!("${work}/runtime-build")?
	create_all!("${work}/runtime-dist")?
	runtime_archive = build_runtime!(root, runtime_sources, zig, "${work}/runtime-build", "${work}/runtime-dist")?
	extracted = "${work}/runtime-extract"
	extract_runtime!(runtime_archive, extracted, LinkInputs.runtime_members)?
	validate_runtime!(extracted)?
	var $payload = []
	for name in LinkInputs.runtime_payload {
		$payload = $payload.append({ name, bytes: read_bytes!("${extracted}/${name}")? })
	}

	nm = JsonValue.get_text(JsonValue.get(runtime_sources, "objcopy")?, "command")?.replace_each("objcopy", "nm")
	audit_macos!(root, zig, work, nm, LinkInputs.macos_symbols(catalog)?)?
	$payload = $payload.concat(windows_files!(root, zig, work)?)

	msvc = "${root}/linker-inputs/msvc-runtime"
	macos = "${root}/linker-inputs/macos-interfaces"
	$payload = $payload.concat([
		{ name: "licenses/mingw-w64.txt", bytes: read_bytes!("${directory_of(zig)}/lib/libc/mingw/COPYING")? },
		{ name: "licenses/roc.txt", bytes: read_bytes!("${msvc}/LICENSE.roc.txt")? },
		{ name: "sources/msvc-runtime-UPSTREAM.json", bytes: read_bytes!("${msvc}/UPSTREAM.json")? },
		{ name: "targets/x64mac/libSystem.tbd", bytes: Str.to_utf8(stub) },
		{ name: "targets/arm64mac/libSystem.tbd", bytes: Str.to_utf8(stub) },
		{ name: "sources/macos-libSystem.json", bytes: read_bytes!("${macos}/libSystem.json")? },
		{ name: "sources/macos-PROVENANCE.md", bytes: read_bytes!("${macos}/PROVENANCE.md")? },
		{ name: "sources/sources.json", bytes: Str.to_utf8(JsonValue.render(sources)) },
	])
	commit = git_commit!(root)?
	epoch = git_epoch!(root)?
	version = JsonValue.get_text(sources, "version")?
	fingerprint = LinkInputs.inputs_fingerprint(sources, runtime_sources, $payload.map(|file| file.name))
	described = $payload.map(|file| { name: file.name, sha256: LinkInputs.sha256(file.bytes), size: file.bytes.len() })
	$payload = $payload.append({ name: "dependency.json", bytes: Str.to_utf8(JsonValue.render(LinkInputs.inputs_manifest({ version, commit, fingerprint, files: described }))) })

	stage = "${work}/payload"
	for file in $payload {
		create_all!(directory_of("${stage}/${file.name}"))?
		write_bytes!("${stage}/${file.name}", file.bytes)?
	}
	archive_name = "roc-zig-linker-inputs-${version}.tar.gz"
	archive = "${output}/${archive_name}"
	write_archive!(stage, $payload.map(|file| file.name), archive, Gzip)?
	verified = exec!(tool(zig, ["run", "tools/link_inputs.zig", "--", "verify-archive", archive], root), "verify-archive ${archive}")?
	if Str.trim(Str.from_utf8_lossy(verified.stdout)) != version {
		return Err("verify-archive reported ${Str.from_utf8_lossy(verified.stdout)}, expected ${version}")
	}

	archive_bytes = read_bytes!(archive)?
	archive_sha256 = LinkInputs.sha256(archive_bytes)
	sbom = Str.to_utf8(JsonValue.render(LinkInputs.inputs_sbom({ version, commit, epoch, archive_sha256, files: $payload.map(|file| { name: file.name, sha256: LinkInputs.sha256(file.bytes) }), sources })))
	write_bytes!("${output}/linker-inputs.spdx.json", sbom)?
	assets = [
		{ name: archive_name, sha256: archive_sha256, size: archive_bytes.len(), role: "archive" },
		{ name: "linker-inputs.spdx.json", sha256: LinkInputs.sha256(sbom), size: sbom.len(), role: "sbom" },
	]
	sums = Str.to_utf8(LinkInputs.sha256sums(assets.map(|asset| { name: asset.name, sha256: asset.sha256 })))
	write_bytes!("${output}/SHA256SUMS", sums)?
	release = LinkInputs.release_dependency({ version, zig_version: JsonValue.get_text(sources, "zig_version")?, commit, fingerprint, assets: assets.append({ name: "SHA256SUMS", sha256: LinkInputs.sha256(sums), size: sums.len(), role: "checksums" }) })
	write_text!("${output}/dependency.json", JsonValue.render(release))?
	say!("Built ${archive}: ${archive_sha256}")
}

## The host's macOS archives must need exactly the catalog's symbols.
audit_macos! : Str, Str, Str, Str, List(Str) => Try({}, Str)
audit_macos! = |root, zig, work, nm, symbols| {
	var $listings = []
	for (name, target) in [("x64", "x86_64-macos"), ("arm64", "aarch64-macos")] {
		archive = "${work}/host-${name}.a"
		say!("Auditing the ${target} host's system symbols")?
		_ = exec!(loud(tool(zig, ["build-lib", "${root}/src/host.zig", "-target", target, "-O", "ReleaseSafe", "-fcompiler-rt", "-femit-bin=${archive}"], root)), "zig build-lib for ${target}")?
		listed = exec!(tool(nm, ["-g", archive], root), "${nm} -g ${archive}")?
		$listings = $listings.append(Str.from_utf8_lossy(listed.stdout))
	}
	LinkInputs.audit_macos($listings, symbols)
}

## The Windows import libraries Zig generates, the MSVC startup archive, and
## a link of the template host with nothing else.
windows_files! : Str, Str, Str => Try(List({ name : Str, bytes : List(U8) }), Str)
windows_files! = |root, zig, work| {
	target_work = "${work}/windows"
	create_all!(target_work)?
	environment = [("ZIG_GLOBAL_CACHE_DIR", "${target_work}/cache"), ("ZIG_LOCAL_CACHE_DIR", "${target_work}/local")]
	say!("Generating the Windows import libraries")?
	ran = exec!(
		tool(zig, ["cc", "-target", "x86_64-windows-gnu", "-O2", "-g0", "-fno-sanitize=all", "-x", "c", "-", "-o", "${target_work}/probe.exe", "-v"], work).envs_str(environment).stdin(Bytes(Str.to_utf8(probe_main))),
		"zig cc for x86_64-windows-gnu",
	)?
	found = LinkInputs.windows_link_inputs(Str.from_utf8_lossy(ran.stderr), LinkInputs.windows_imports, work)?
	var $files = [{ name: "targets/x64win/${LinkInputs.windows_runtime}", bytes: msvc_runtime!(root, zig, target_work, environment)? }]
	for input in found {
		if !is_file!(input.path) {
			return Err("Incomplete Windows linker inputs: ${input.name}")
		}
		$files = $files.append({ name: "targets/x64win/${input.name}", bytes: read_bytes!(input.path)? })
	}
	check_windows_link!(root, zig, target_work, environment, $files)?
	Ok($files)
}

## Build the MSVC-ABI startup archive: the entry point lld-link infers for a
## console program, the TLS directory and compiler-rt, one archive member each.
msvc_runtime! : Str, Str, Str, List((Str, Str)) => Try(List(U8), Str)
msvc_runtime! = |root, zig, work, environment| {
	vendored = "${root}/linker-inputs/msvc-runtime"
	recorded = JsonValue.fields(JsonValue.get(json!("${vendored}/UPSTREAM.json")?, "files")?)?
	if JsonValue.sort(recorded.map(|field| field.key)) != JsonValue.sort(LinkInputs.msvc_runtime_sources) {
		return Err("Unexpected MSVC runtime sources")
	}
	build = "${work}/msvc-runtime"
	create_all!(build)?
	for field in recorded {
		data = read_bytes!("${vendored}/${field.key}")?
		if JsonValue.compact(field.value) != JsonValue.compact(JsonValue.text(LinkInputs.sha256(data))) {
			return Err("Vendored MSVC runtime source differs from UPSTREAM.json: ${field.key}")
		}
		write_bytes!("${build}/${field.key}", data)?
	}
	say!("Building the MSVC runtime")?
	# -j1: Zig numbers a local `__anon_N` symbol by the compiler thread that made it.
	common = ["-target", "x86_64-windows-msvc", "-O", "ReleaseFast", "-fstrip", "-fno-stack-check", "-j1"]
	_ = exec!(loud(tool(zig, ["build-obj", "tls.zig"].concat(common).append("-femit-bin=tls.obj"), build).envs_str(environment)), "zig build-obj tls.zig")?
	_ = exec!(loud(tool(zig, ["build-lib", "exe_startup.zig", "tls.obj"].concat(common).concat(["-fcompiler-rt", "-femit-bin=unnormalized.lib"]), build).envs_str(environment)), "zig build-lib exe_startup.zig")?
	# Zig's archive names its members by cache path; rebuild it with stable names.
	listed = exec!(tool(zig, ["ar", "t", "unnormalized.lib"], build), "zig ar t unnormalized.lib")?
	members = lines(listed.stdout).map(|member| { name: LinkInputs.basename(member.replace_each("\\", "/")), member })
	if JsonValue.sort(members.map(|m| m.name)) != JsonValue.sort(LinkInputs.msvc_runtime_members) {
		return Err("Unexpected MSVC runtime archive members: ${Str.join_with(JsonValue.sort(members.map(|m| m.name)), ", ")}")
	}
	objects = "${build}/objects"
	create_all!(objects)?
	for name in LinkInputs.msvc_runtime_members {
		member = (members.find_first(|m| m.name == name) ?? { name, member: name }).member
		extracted = exec!(tool(zig, ["ar", "pP", "unnormalized.lib", member], build), "zig ar p ${member}")?
		write_bytes!("${objects}/${name}", extracted.stdout)?
	}
	_ = exec!(tool(zig, ["ar", "--format=coff", "rcsD", LinkInputs.windows_runtime].concat(LinkInputs.msvc_runtime_members), objects), "zig ar ${LinkInputs.windows_runtime}")?
	read_bytes!("${objects}/${LinkInputs.windows_runtime}")
}

## Link the template host the way Roc does for x64win: only the listed inputs,
## nothing from the machine, and the entry point left for lld-link to infer.
check_windows_link! : Str, Str, Str, List((Str, Str)), List({ name : Str, bytes : List(U8) }) => Try({}, Str)
check_windows_link! = |root, zig, work, environment, files| {
	link = "${work}/windows-link"
	create_all!(link)?
	for file in files {
		write_bytes!("${link}/${LinkInputs.basename(file.name)}", file.bytes)?
	}
	say!("Checking the Windows link")?
	_ = exec!(loud(tool(zig, ["build-lib", "${root}/src/host.zig", "-target", "x86_64-windows-msvc", "-O", "ReleaseSafe", "-fcompiler-rt", "-femit-bin=host.lib"], link).envs_str(environment)), "zig build-lib for x86_64-windows-msvc")?
	_ = exec!(loud(tool(zig, ["cc", "-target", "x86_64-windows-msvc", "-O2", "-g0", "-nostdinc", "-c", "-x", "c", "-", "-o", "app.obj"], link).envs_str(environment).stdin(Bytes(Str.to_utf8("int roc_main(void) { return 0; }\n")))), "zig cc app.obj")?
	_ = exec!(loud(tool(zig, ["lld-link", "/nodefaultlib", "/subsystem:console", "/machine:x64", "/opt:ref", "/out:probe.exe", "/wholearchive:host.lib", "app.obj"].concat(LinkInputs.windows_files), link).envs_str(environment)), "zig lld-link")?
	Ok({})
}

# ---------------------------------------------------------------- release

## Repackage the tested aggregate linker inputs for the trusted PR publisher.
release! : Str, Str, Str => Try({}, Str)
release! = |root, source, output| {
	archives = Path.list!(Path.unix(source)).map_err(|_| "cannot list ${source}")?.map(Path.display).keep_if(
		|path| {
			name = LinkInputs.basename(path)
			name.starts_with("roc-zig-linker-inputs-") and name.ends_with(".tar.gz")
		},
	)
	archive = match archives {
		[only] => only
		_ => return Err("expected one tested aggregate archive")
	}
	if (Path.size_in_bytes!(Path.unix(archive)) ?? 0) > 256 * 1024 * 1024 {
		return Err("Linker-input archive exceeds size limit")
	}
	repository = env!("GITHUB_REPOSITORY")?
	sha = env!("GITHUB_SHA")?
	ref = env!("GITHUB_REF")?
	fingerprint = producer_fingerprint!(root)?
	in_work!(
		root,
		"link-input-release-",
		|work| {
			listing = exec!(tool("tar", ["-tvzf", archive], work), "tar -tv ${archive}")?
			entries = LinkInputs.tar_entries(Str.from_utf8_lossy(listing.stdout), 512 * 1024 * 1024)?
			if entries.any(|entry| entry.directory) {
				return Err("Unsafe or duplicate archive entry")
			}
			names = entries.map(|entry| entry.name)
			extracted = "${work}/inputs"
			create_all!(extracted)?
			_ = exec!(tool("tar", ["-xzf", archive, "-C", extracted, "--no-same-owner", "--no-same-permissions", "--"].concat(names), work), "tar -x ${archive}")?
			var $files = []
			for name in names {
				bytes = read_bytes!("${extracted}/${name}")?
				$files = $files.append({ name, sha256: LinkInputs.sha256(bytes), size: bytes.len() })
			}
			if !names.contains("dependency.json") {
				return Err("Linker-input archive has no dependency.json")
			}
			_ = LinkInputs.verify_inputs(read_text!("${extracted}/dependency.json")?, $files.keep_if(|file| file.name != "dependency.json"))?
			new_directory!(output)?
			asset = "${output}/link-inputs-all.tar"
			write_archive!(extracted, names, asset, Plain)?
			bytes = read_bytes!(asset)?
			write_text!("${output}/build-input-release.json", LinkInputs.build_input_release({ repository, sha, ref, fingerprint, asset: "link-inputs-all.tar", sha256: LinkInputs.sha256(bytes), size: bytes.len() }))?
			say!("Prepared ${asset}")
		},
	)
}

producer_fingerprint! : Str => Try(Str, Str)
producer_fingerprint! = |root| {
	var $records = []
	for name in LinkInputs.producer_inputs {
		blob = match tool("git", ["rev-parse", "HEAD:${name}"], root).stderr(Null).run!() {
			Ok({ status: Exited(0), stdout_bytes, .. }) => Str.trim(Str.from_utf8_lossy(stdout_bytes))
			_ => ""
		}
		$records = $records.append({ name, blob })
	}
	LinkInputs.producer_fingerprint($records)
}

# ---------------------------------------------------------------- toolchain

## Download the locked Zig distribution for this machine, check its SHA-256
## and minisign signature, and extract it; returns the `zig` executable.
toolchain! : Str, JsonValue => Try(Str, Str)
toolchain! = |work, lock| {
	arch = machine!()?
	source = JsonValue.get(JsonValue.get(lock, "toolchains")?, "${arch}-linux")?
	url = JsonValue.get_text(source, "url")?
	archive = "${work}/zig.tar.xz"
	signature = "${work}/zig.minisig"
	say!("Downloading ${url}")?
	download!(url, archive)?
	if LinkInputs.sha256(read_bytes!(archive)?) != JsonValue.get_text(source, "sha256")? {
		return Err("Zig distribution checksum mismatch")
	}
	download!("${url}.minisig", signature)?
	_ = exec!(loud(tool("minisign", ["-Vm", archive, "-x", signature, "-P", JsonValue.get_text(lock, "zig_minisign_key")?], work)), "minisign verification of ${url}")?
	installed = "${work}/toolchain"
	listing = exec!(tool("tar", ["-tvJf", archive], work).output_limit(256 * 1024 * 1024), "tar -tv ${archive}")?
	_ = LinkInputs.tar_entries(Str.from_utf8_lossy(listing.stdout), 2_000_000_000)?
	create_all!(installed)?
	_ = exec!(tool("tar", ["-xJf", archive, "-C", installed, "--no-same-owner"], work), "tar -x ${archive}")?
	var $executables = []
	for entry in Path.list!(Path.unix(installed)).map_err(|_| "cannot list ${installed}")? {
		candidate = "${Path.display(entry)}/zig"
		if is_file!(candidate) {
			$executables = $executables.append(candidate)
		}
	}
	zig = match $executables {
		[only] => only
		_ => return Err("Unexpected Zig distribution layout")
	}
	reported = exec!(tool(zig, ["version"], work), "zig version")?
	if Str.trim(Str.from_utf8_lossy(reported.stdout)) != JsonValue.get_text(lock, "zig_version")? {
		return Err("Zig executable version mismatch")
	}
	Ok(zig)
}

download! : Str, Str => Try({}, Str)
download! = |url, destination| {
	_ = exec!(tool("curl", ["--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--retry", "3", "--output", destination, url], "/"), "download of ${url}")?
	Ok({})
}

check_objcopy! : JsonValue => Try({}, Str)
check_objcopy! = |lock| {
	objcopy = JsonValue.get(lock, "objcopy")?
	command = JsonValue.get_text(objcopy, "command")?
	reported = exec!(tool(command, ["--version"], "/"), "${command} --version")?
	if Str.from_utf8_lossy(reported.stdout).contains(JsonValue.get_text(objcopy, "version")?) {
		Ok({})
	} else {
		Err("Unexpected llvm-objcopy version")
	}
}

machine! : () => Try(Str, Str)
machine! = || {
	host = Env.platform!()
	match (host.os, host.arch) {
		(LINUX, X64) => Ok("x86_64")
		(LINUX, AARCH64) => Ok("aarch64")
		_ => Err("The linker-input producer requires x86-64 or ARM64 Linux")
	}
}

# ---------------------------------------------------------------- primitives

## Write a deterministic ustar archive of `names` under `stage`, sorted by name.
write_archive! : Str, List(Str), Str, [Gzip, Plain] => Try({}, Str)
write_archive! = |stage, names, destination, compression| {
	ordered = LinkInputs.archive_order(names)?
	tarball = "${destination}.tar-partial"
	list = Str.to_utf8(Str.join_with(ordered, "\u(0000)"))
	_ = exec!(
		tool("tar", ["--create", "--file=${tarball}", "--format=ustar", "--sort=name", "--mtime=@0", "--owner=0", "--group=0", "--numeric-owner", "--mode=0644", "--no-recursion", "--directory=${stage}", "--null", "--verbatim-files-from", "--files-from=-"], stage).stdin(Bytes(list)),
		"tar --create ${destination}",
	)?
	match compression {
		Plain => rename!(tarball, destination)
		Gzip => {
			_ = exec!(tool("gzip", ["-n", "-9", "--suffix=.gz", tarball], stage), "gzip ${tarball}")?
			rename!("${tarball}.gz", destination)
		}
	}
}

## Run `work!` in a fresh directory under `.zig-cache`, then delete it.
in_work! : Str, Str, (Str => Try(a, Str)) => Try({}, Str)
in_work! = |root, prefix, work!| {
	create_all!("${root}/.zig-cache")?
	directory = Path.display(Env.create_temp_dir_in!(Path.unix("${root}/.zig-cache"), prefix).map_err(|_| "cannot create a work directory")?)
	result = work!(directory)
	_ = Path.delete_all!(Path.unix(directory))
	result.map_ok(|_| {})
}

Ran : { stdout : List(U8), stderr : List(U8) }

## Run a command to completion; anything but a zero exit status is an error.
exec! : Cmd, Str => Try(Ran, Str)
exec! = |command, what|
	match command.run!() {
		Ok({ status: Exited(0), stdout_bytes, stderr_bytes }) => Ok({ stdout: stdout_bytes, stderr: stderr_bytes })
		Ok({ status: Exited(code), stderr_bytes, .. }) => Err("${what} exited with code ${code.to_str()}\n${Str.from_utf8_lossy(stderr_bytes)}")
		Ok({ status: Signaled(signal), .. }) => Err("${what} was killed by signal ${signal.to_str()}")
		Err(OutputLimit(_)) => Err("${what} printed more than the output limit")
		Err(_) => Err("could not run ${what}")
	}

tool : Str, List(Str), Str -> Cmd
tool = |program, args, cwd| Cmd.new_str(program).args_str(args).cwd(Path.unix(cwd)).output_limit(1024 * 1024 * 1024)

## Show the command's output as it runs instead of capturing it.
loud : Cmd -> Cmd
loud = |command| command.stdout(Inherit).stderr(Inherit)

lines : List(U8) -> List(Str)
lines = |bytes| Str.split_on(Str.from_utf8_lossy(bytes), "\n").map(|line| line.drop_suffix("\r")).keep_if(|line| line != "")

## Every regular file under `directory`, relative to it; links are errors.
walk! : Str, Str => Try(List(Str), Str)
walk! = |directory, prefix| {
	var $found = []
	for entry in Path.list!(Path.unix(directory)).map_err(|_| "cannot list ${directory}")? {
		name = LinkInputs.basename(Path.display(entry))
		match Path.type!(entry) {
			Ok(IsFile) => {
				$found = $found.append("${prefix}${name}")
			}
			Ok(IsDir) => {
				$found = $found.concat(walk!(Path.display(entry), "${prefix}${name}/")?)
			}
			_ => return Err("Unexpected runtime contents: ${prefix}${name}")
		}
	}
	Ok($found)
}

git_commit! : Str => Try(Str, Str)
git_commit! = |root| {
	ran = exec!(tool("git", ["rev-parse", "HEAD"], root), "git rev-parse HEAD")?
	Ok(Str.trim(Str.from_utf8_lossy(ran.stdout)))
}

git_epoch! : Str => Try(I64, Str)
git_epoch! = |root| {
	ran = exec!(tool("git", ["show", "-s", "--format=%ct", "HEAD"], root), "git show HEAD")?
	I64.from_str(Str.trim(Str.from_utf8_lossy(ran.stdout))).map_err(|_| "cannot read the commit time")
}

env! : Str => Try(Str, Str)
env! = |name| Env.var_str!(OsStr.from_str(name)).map_err(|_| "${name} must be set")

json! : Str => Try(JsonValue, Str)
json! = |path| JsonValue.parse(read_text!(path)?).map_err(|problem| "${path}: ${problem}")

directory_of : Str -> Str
directory_of = |path|
	match Str.split_last(path, "/") {
		Ok({ before, .. }) => before
		Err(NotFound) => "."
	}

new_directory! : Str => Try({}, Str)
new_directory! = |path| {
	if Path.exists!(Path.unix(path)) ?? Bool.True {
		return Err("${path} already exists")
	}
	create_all!(path)
}

is_file! : Str => Bool
is_file! = |path| Path.is_file!(Path.unix(path)) ?? Bool.False

create_all! : Str => Try({}, Str)
create_all! = |path| Path.create_all!(Path.unix(path)).map_err(|_| "cannot create ${path}")

copy! : Str, Str => Try({}, Str)
copy! = |source, destination| {
	create_all!(directory_of(destination))?
	write_bytes!(destination, read_bytes!(source)?)
}

rename! : Str, Str => Try({}, Str)
rename! = |source, destination| Path.rename!(Path.unix(source), Path.unix(destination)).map_err(|_| "cannot move ${source} to ${destination}")

read_text! : Str => Try(Str, Str)
read_text! = |path| Path.read_utf8!(Path.unix(path)).map_err(|_| "cannot read ${path}")

read_bytes! : Str => Try(List(U8), Str)
read_bytes! = |path| Path.read_bytes!(Path.unix(path)).map_err(|_| "cannot read ${path}")

write_bytes! : Str, List(U8) => Try({}, Str)
write_bytes! = |path, bytes| Path.write_bytes!(Path.unix(path), bytes).map_err(|_| "cannot write ${path}")

write_text! : Str, Str => Try({}, Str)
write_text! = |path, text| write_bytes!(path, Str.to_utf8(text))

say! : Str => Try({}, Str)
say! = |line| Stdout.line!(line).map_err(|_| "cannot write to stdout")
