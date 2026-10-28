import JsonValue

## Pure parts of `scripts/build_link_inputs.roc`: what the Linux runtime and the
## aggregate linker-input release contain, how Zig's linker traces name those
## inputs, and the manifests, SBOMs and checksums that describe them.
LinkInputs := [].{

	## The Linux runtime files, in link order: the startup object first.
	runtime_files : List(Str)
	runtime_files = ["crt1.o", "libc.a", "libzigc.a", "libcompiler_rt.a"]

	runtime_targets : List(Str)
	runtime_targets = ["x64musl", "arm64musl"]

	runtime_licenses : List(Str)
	runtime_licenses = ["licenses/Zig.txt", "licenses/musl.txt"]

	## Every member of a runtime archive.
	runtime_members : List(Str)
	runtime_members = JsonValue.sort(runtime_payload.append("manifest.json"))

	## The runtime files the aggregate linker inputs carry.
	runtime_payload : List(Str)
	runtime_payload = runtime_targets.join_map(|target| runtime_files.map(|name| "targets/${target}/${name}")).concat(runtime_licenses)

	windows_imports : List(Str)
	windows_imports = [
		"api-ms-win-crt-conio-l1-1-0.lib",
		"api-ms-win-crt-convert-l1-1-0.lib",
		"api-ms-win-crt-environment-l1-1-0.lib",
		"api-ms-win-crt-filesystem-l1-1-0.lib",
		"api-ms-win-crt-heap-l1-1-0.lib",
		"api-ms-win-crt-locale-l1-1-0.lib",
		"api-ms-win-crt-math-l1-1-0.lib",
		"api-ms-win-crt-multibyte-l1-1-0.lib",
		"api-ms-win-crt-private-l1-1-0.lib",
		"api-ms-win-crt-process-l1-1-0.lib",
		"api-ms-win-crt-runtime-l1-1-0.lib",
		"api-ms-win-crt-stdio-l1-1-0.lib",
		"api-ms-win-crt-string-l1-1-0.lib",
		"api-ms-win-crt-time-l1-1-0.lib",
		"api-ms-win-crt-utility-l1-1-0.lib",
		"advapi32.lib",
		"kernel32.lib",
		"ntdll.lib",
		"shell32.lib",
		"user32.lib",
	]

	msvc_runtime_sources : List(Str)
	msvc_runtime_sources = ["exe_startup.zig", "initializers.zig", "tls.zig"]

	## Zig names an archive member after the object it compiled; these are the stable names.
	msvc_runtime_members : List(Str)
	msvc_runtime_members = ["exe_startup_zcu.obj", "tls.obj", "compiler_rt.obj"]

	windows_runtime : Str
	windows_runtime = "msvc_runtime.lib"

	## The Windows inputs, in the order the link check passes them.
	windows_files : List(Str)
	windows_files = [windows_runtime].concat(windows_imports)

	release_targets : List(Str)
	release_targets = ["x64mac", "arm64mac", "x64win", "x64musl", "x64v1musl", "arm64musl", "arm64v1musl"]

	## The committed files whose git blobs identify the producer of a release.
	producer_inputs : List(Str)
	producer_inputs = [
		"linker-inputs/sources.json",
		"linker-inputs/macos-interfaces/libSystem.json",
		"linker-inputs/macos-interfaces/PROVENANCE.md",
		"linker-inputs/msvc-runtime/UPSTREAM.json",
		"linker-inputs/msvc-runtime/exe_startup.zig",
		"linker-inputs/msvc-runtime/initializers.zig",
		"linker-inputs/msvc-runtime/tls.zig",
		"linker-inputs/msvc-runtime/LICENSE.roc.txt",
		"runtime/sources.json",
		"scripts/build_link_inputs.roc",
		"scripts/src/LinkInputs.roc",
		"scripts/src/JsonValue.roc",
		".github/workflows/linker-inputs.yml",
	]

	## Split a command line the way a POSIX shell (and Python's `shlex.split`) does.
	shell_split : Str -> Try(List(Str), Str)
	shell_split = |line| split_words(Str.to_utf8(line), Between, [], [])

	## Resolve `.` and `..` in a path without touching the file system. A
	## relative path is taken relative to `base`.
	absolute : Str, Str -> Str
	absolute = |base, path| {
		joined = if (path.starts_with("/")) path else "${base}/${path}"
		parts = Str.split_on(joined, "/").fold(
			[],
			|kept, part|
				if part == "" or part == "." {
					kept
				} else if part == ".." {
					kept.drop_last(1)
				} else {
					kept.append(part)
				},
		)
		"/${Str.join_with(parts, "/")}"
	}

	## The final component of a `/`-separated path.
	basename : Str -> Str
	basename = |path|
		match Str.split_last(path, "/") {
			Ok({ after, .. }) => after
			Err(NotFound) => path
		}

	## The Linux runtime inputs named by the one final `ld.lld` invocation that
	## `zig cc -v` printed, as absolute paths inside the isolated `cache`, in
	## the order the linker received them. Any other library is an error.
	runtime_link_inputs : Str, Str -> Try(List({ name : Str, path : Str }), Str)
	runtime_link_inputs = |log, cache| {
		lines = lines_of(log).keep_if(|line| line.starts_with("ld.lld ") and !line.contains(" -r "))
		line = match lines {
			[only] => only
			_ => return Err("Expected exactly one Zig linker invocation:\n${log}")
		}
		root = LinkInputs.absolute("/", cache)
		parent = LinkInputs.absolute(root, "..")
		var $found = []
		for token in shell_split(line)?.drop_first(1) {
			path = LinkInputs.absolute(parent, token)
			name = basename(path)
			if runtime_files.contains(name) {
				if $found.any(|input| input.name == name) or !path.starts_with("${root}/") {
					return Err("Unexpected runtime linker input: ${token}")
				}
				$found = $found.append({ name, path })
			} else if token.ends_with(".a") {
				return Err("Unexpected linker library: ${token}")
			}
		}
		if JsonValue.sort($found.map(|input| input.name)) != JsonValue.sort(runtime_files) {
			return Err("Incomplete Zig runtime inputs: ${Str.join_with($found.map(|input| input.name), ", ")}")
		}
		Ok($found)
	}

	## The import libraries named by the `lld-link` invocation that `zig cc -v`
	## printed for a Windows target, as absolute paths, in the order of `names`.
	windows_link_inputs : Str, List(Str), Str -> Try(List({ name : Str, path : Str }), Str)
	windows_link_inputs = |trace, names, work| {
		var $found = []
		for line in lines_of(trace) {
			if line.starts_with("lld-link ") {
				for token in shell_split(line)? {
					normalized = token.replace_each("\\", "/")
					for name in names {
						if normalized.ends_with("/${name}") {
							$found = $found.keep_if(|input| input.name != name).append({ name, path: LinkInputs.absolute(work, token) })
						}
					}
				}
			}
		}
		missing = JsonValue.sort(names.keep_if(|name| !$found.any(|input| input.name == name)))
		if !missing.is_empty() {
			return Err("Incomplete Windows linker inputs: ${Str.join_with(missing, ", ")}")
		}
		Ok(names.map(|name| $found.find_first(|input| input.name == name) ?? { name, path: "" }))
	}

	## The symbols an archive needs but does not define, from `nm -g` output.
	unresolved : Str -> List(Str)
	unresolved = |listing| {
		rows = lines_of(listing).map(words)
		undefined = rows.keep_if(|parts| parts.len() == 2 and parts.first() == Ok("U")).map(|parts| parts.last() ?? "")
		defined = rows.keep_if(|parts| parts.len() >= 3 and !["U", "u"].contains(parts.get(parts.len() - 2) ?? "")).map(|parts| parts.last() ?? "")
		unique(undefined.keep_if(|symbol| !defined.contains(symbol)))
	}

	## Check the macOS interface catalog against what the host's archives
	## need from the system, from each archive's `nm -g` output.
	audit_macos : List(Str), List(Str) -> Try({}, Str)
	audit_macos = |listings, symbols| {
		needed = unique(listings.join_map(LinkInputs.unresolved).keep_if(|symbol| symbol != "_roc_main"))
		catalog = unique(symbols)
		if needed == catalog {
			Ok({})
		} else {
			missing = needed.keep_if(|symbol| !catalog.contains(symbol))
			extra = catalog.keep_if(|symbol| !needed.contains(symbol))
			Err("macOS interface catalog differs from host audit; missing=${JsonValue.spaced(JsonValue.texts(missing))}, extra=${JsonValue.spaced(JsonValue.texts(extra))}")
		}
	}

	## The symbols of a valid macOS interface catalog.
	macos_symbols : JsonValue -> Try(List(Str), Str)
	macos_symbols = |catalog| {
		invalid = "Invalid macOS interface catalog"
		if JsonValue.sort(JsonValue.keys(catalog)) != ["evidence", "install_name", "library", "schema", "symbols", "targets"] {
			return Err(invalid)
		}
		if JsonValue.integer(JsonValue.get(catalog, "schema")?) != Ok(1) or JsonValue.strings(JsonValue.get(catalog, "targets")?) != Ok(["x86_64-macos", "arm64-macos"]) {
			return Err(invalid)
		}
		symbols = JsonValue.strings(JsonValue.get(catalog, "symbols")?)?
		if symbols != unique(symbols) {
			return Err("macOS symbols must be unique and sorted")
		}
		Ok(symbols)
	}

	## The text-based dual-architecture libSystem stub for a valid catalog.
	macos_stub : JsonValue -> Try(Str, Str)
	macos_stub = |catalog| {
		symbols = macos_symbols(catalog)?
		install_name = JsonValue.get_text(catalog, "install_name")?
		lines = [
			"--- !tapi-tbd",
			"tbd-version:     4",
			"targets:         [ x86_64-macos, arm64-macos ]",
			"install-name:    ${install_name}",
			"exports:",
			"  - targets:         [ x86_64-macos, arm64-macos ]",
			"    symbols:",
		]
			.concat(symbols.map(|symbol| "      - '${symbol}'"))
			.append("...")
		Ok("${Str.join_with(lines, "\n")}\n")
	}

	## The x64win inputs a platform header lists, in order; `app` is unquoted.
	windows_header_inputs : Str -> Try(List(Str), Str)
	windows_header_inputs = |header|
		match Str.split_first(header, "x64win: { inputs: [") {
			Ok({ after, .. }) =>
				match Str.split_first(after, "] }") {
					Ok({ before, .. }) => Ok(Str.split_on(before, ",").map(|item| item.trim().replace_each("\"", "")).keep_if(|item| item != ""))
					Err(NotFound) => Err("unterminated x64win inputs")
				}
			Err(NotFound) => Err("the platform header lists no x64win inputs")
		}

	## Whether a platform header lists the host whole, then the app, then
	## exactly the released Windows inputs with the startup archive first.
	valid_windows_header : Str -> Bool
	valid_windows_header = |header|
		match LinkInputs.windows_header_inputs(header) {
			Ok(inputs) => inputs.take_first(3) == ["host.lib", "app", windows_runtime] and JsonValue.sort(inputs.drop_first(2)) == JsonValue.sort(windows_files)
			Err(_) => Bool.False
		}

	## An ISO 8601 UTC timestamp to the second, like `2026-10-04T12:00:00Z`.
	utc : I64 -> Str
	utc = |epoch| {
		days = epoch // 86400
		seconds = epoch % 86400
		z = days + 719468
		era = z // 146097
		doe = z - era * 146097
		yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
		doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
		mp = (5 * doy + 2) // 153
		day = doy - (153 * mp + 2) // 5 + 1
		month = if (mp < 10) mp + 3 else mp - 9
		year = yoe + era * 400 + if (month <= 2) 1 else 0
		"${year.to_str()}-${pad(month)}-${pad(day)}T${pad(seconds // 3600)}:${pad((seconds // 60) % 60)}:${pad(seconds % 60)}Z"
	}

	## A name that is safe inside an archive: relative, `/`-separated, with no
	## empty, `.` or `..` component, backslash or colon.
	safe_name : Str -> Bool
	safe_name = |name|
		name != "" and !name.starts_with("/") and !name.contains("\\") and !name.contains(":") and Str.split_on(name, "/").all(|part| part != "" and part != "." and part != "..")

	## The members of a deterministic archive, in the order they are written.
	archive_order : List(Str) -> Try(List(Str), Str)
	archive_order = |names| {
		for name in names {
			if !LinkInputs.safe_name(name) {
				return Err("Unsafe linker-input path: ${name}")
			}
		}
		ordered = JsonValue.sort(names)
		if unique(ordered).len() != ordered.len() {
			return Err("duplicate archive member")
		}
		Ok(ordered)
	}

	## The entries of a `tar -tv` listing. Only regular files and directories
	## with safe, unique names are accepted, up to `limit` unpacked bytes.
	tar_entries : Str, U64 -> Try(List({ name : Str, directory : Bool, size : U64 }), Str)
	tar_entries = |listing, limit| {
		var $entries = []
		var $total = 0
		for line in lines_of(listing) {
			parts = words(line)
			if parts.len() != 6 {
				return Err("Unsafe archive member: ${line}")
			}
			mode = parts.first() ?? ""
			directory = mode.starts_with("d")
			raw = parts.last() ?? ""
			name = if (directory) raw.drop_suffix("/") else raw
			size = U64.from_str(parts.get(2) ?? "") ?? 0
			if !(directory or mode.starts_with("-")) or !LinkInputs.safe_name(name) or $entries.any(|entry| entry.name == name) {
				return Err("Unsafe archive member: ${raw}")
			}
			$total = $total + size
			if $total > limit {
				return Err("Archive exceeds extraction size limit")
			}
			$entries = $entries.append({ name, directory, size })
		}
		Ok($entries)
	}

	## Check a runtime archive's listing names exactly the runtime members.
	runtime_listing : Str -> Try({}, Str)
	runtime_listing = |listing| {
		entries = LinkInputs.tar_entries(listing, 2_000_000_000)?
		for entry in entries {
			if entry.directory or !runtime_members.contains(entry.name) {
				return Err("Unexpected archive member: ${entry.name}")
			}
		}
		if JsonValue.sort(entries.map(|entry| entry.name)) != runtime_members {
			return Err("Incomplete runtime archive")
		}
		Ok({})
	}

	## Check a runtime `manifest.json` lists exactly the runtime files, and
	## return each with its recorded SHA-256.
	runtime_inventory : Str -> Try(List({ name : Str, sha256 : Str }), Str)
	runtime_inventory = |text| {
		manifest = JsonValue.parse(text)?
		files = JsonValue.fields(JsonValue.get(manifest, "files")?)?
		if JsonValue.integer(JsonValue.get(manifest, "schema")?) != Ok(1) or JsonValue.sort(files.map(|field| field.key)) != JsonValue.sort(runtime_payload) {
			return Err("Invalid runtime inventory")
		}
		var $inventory = []
		for field in files {
			match field.value {
				Text(sha256) => {
					$inventory = $inventory.append({ name: field.key, sha256 })
				}
				_ => return Err("Invalid runtime inventory")
			}
		}
		Ok($inventory)
	}

	## The runtime's `manifest.json`.
	runtime_manifest : { version : Str, commit : Str, lock : JsonValue, commands : List({ target : Str, argv : List(Str) }), builder : Str, files : List({ name : Str, sha256 : Str }) } -> JsonValue
	runtime_manifest = |m|
		JsonValue.object([
			("schema", JsonValue.number(1)),
			("version", JsonValue.text(m.version)),
			("source_commit", JsonValue.text(m.commit)),
			("sources", m.lock),
			("commands", JsonValue.object(m.commands.map(|command| (command.target, JsonValue.texts(command.argv))))),
			("builder_platform", JsonValue.text(m.builder)),
			("files", JsonValue.object(m.files.map(|file| (file.name, JsonValue.text(file.sha256))))),
		])

	## The runtime's SPDX document.
	runtime_sbom : { version : Str, lock : JsonValue, builder : Str, files : List({ name : Str, sha256 : Str }), archive_sha256 : Str, epoch : I64 } -> Try(JsonValue, Str)
	runtime_sbom = |s| {
		zig_version = JsonValue.get_text(s.lock, "zig_version")?
		musl_version = JsonValue.get_text(s.lock, "musl_version")?
		compiler = JsonValue.get(JsonValue.get(s.lock, "toolchains")?, s.builder)?
		objcopy = JsonValue.get(s.lock, "objcopy")?
		zig_download = "https://ziglang.org/download/${zig_version}/"
		spdx_package = |ident, name, version, location, license, extra|
			JsonValue.object(
				[
					("SPDXID", JsonValue.text("SPDXRef-${ident}")),
					("name", JsonValue.text(name)),
					("versionInfo", JsonValue.text(version)),
					("downloadLocation", JsonValue.text(location)),
					("filesAnalyzed", Boolean(Bool.False)),
					("licenseConcluded", JsonValue.text("NOASSERTION")),
					("licenseDeclared", JsonValue.text(license)),
					("copyrightText", JsonValue.text("NOASSERTION")),
				].concat(extra),
			)
		spdx_packages = [
			spdx_package("runtime", "roc-platform-linux-runtime", s.version, "NOASSERTION", "NOASSERTION", [checksums(s.archive_sha256)]),
			spdx_package("musl", "musl (Zig distribution)", musl_version, zig_download, "NOASSERTION", []),
			spdx_package("zig-libc", "Zig libc", zig_version, zig_download, "MIT", []),
			spdx_package("compiler-rt", "Zig compiler runtime", zig_version, zig_download, "MIT", []),
			spdx_package("zig", "Zig compiler distribution", zig_version, JsonValue.get_text(compiler, "url")?, "NOASSERTION", [checksums(JsonValue.get_text(compiler, "sha256")?)]),
			spdx_package("objcopy", "LLVM objcopy", JsonValue.get_text(objcopy, "version")?, JsonValue.get_text(objcopy, "source")?, "Apache-2.0 WITH LLVM-exception", []),
		]
		files = sorted_files(s.files)
		relationships = [
			relationship("SPDXRef-DOCUMENT", "DESCRIBES", "SPDXRef-runtime"),
			relationship("SPDXRef-runtime", "DEPENDS_ON", "SPDXRef-musl"),
			relationship("SPDXRef-runtime", "DEPENDS_ON", "SPDXRef-zig-libc"),
			relationship("SPDXRef-runtime", "DEPENDS_ON", "SPDXRef-compiler-rt"),
			relationship("SPDXRef-zig", "BUILD_TOOL_OF", "SPDXRef-runtime"),
			relationship("SPDXRef-objcopy", "BUILD_TOOL_OF", "SPDXRef-runtime"),
		].concat(files.map_with_index(|_, index| relationship("SPDXRef-runtime", "CONTAINS", "SPDXRef-file-${index.to_str()}")))
		Ok(
			JsonValue.object([
				("spdxVersion", JsonValue.text("SPDX-2.3")),
				("dataLicense", JsonValue.text("CC0-1.0")),
				("SPDXID", JsonValue.text("SPDXRef-DOCUMENT")),
				("name", JsonValue.text("roc-platform-runtime-${s.version}")),
				("documentNamespace", JsonValue.text("https://spdx.org/spdxdocs/roc-runtime-${s.archive_sha256}")),
				("creationInfo", creation(s.epoch, "Tool: roc-platform-template-zig-runtime-builder")),
				("packages", JsonValue.array(spdx_packages)),
				("files", JsonValue.array(files.map_with_index(spdx_file))),
				("relationships", JsonValue.array(relationships)),
			]),
		)
	}

	## What the aggregate archive's fingerprint is computed over.
	inputs_fingerprint : JsonValue, JsonValue, List(Str) -> Str
	inputs_fingerprint = |sources, runtime_sources, names|
		sha256_text(JsonValue.render(JsonValue.object([("sources", sources), ("runtime_sources", runtime_sources), ("files", JsonValue.texts(JsonValue.sort(names)))])))

	## The `dependency.json` inside the aggregate archive.
	inputs_manifest : { version : Str, commit : Str, fingerprint : Str, files : List({ name : Str, sha256 : Str, size : U64 }) } -> JsonValue
	inputs_manifest = |m|
		JsonValue.object([
			("schema", JsonValue.number(1)),
			("version", JsonValue.text(m.version)),
			("source_commit", JsonValue.text(m.commit)),
			("input_fingerprint", JsonValue.text(m.fingerprint)),
			("files", JsonValue.object(m.files.map(|file| (file.name, JsonValue.object([("sha256", JsonValue.text(file.sha256)), ("size", size(file.size))]))))),
		])

	## Check an aggregate archive's `dependency.json` against the files beside
	## it, as the platform's consumer does, and return its version.
	verify_inputs : Str, List({ name : Str, sha256 : Str, size : U64 }) -> Try(Str, Str)
	verify_inputs = |text, files| {
		invalid = Err("Invalid linker-input dependency manifest")
		manifest = JsonValue.parse(text)?
		version = JsonValue.get_text(manifest, "version") ?? ""
		recorded = JsonValue.fields(JsonValue.get(manifest, "files") ?? JsonValue.object([])) ?? []
		if JsonValue.integer(JsonValue.get(manifest, "schema") ?? JsonValue.object([])) != Ok(1) or !is_version(version) or !is_hex(JsonValue.get_text(manifest, "source_commit") ?? "", 40) or !is_hex(JsonValue.get_text(manifest, "input_fingerprint") ?? "", 64) {
			return invalid
		}
		if JsonValue.sort(recorded.map(|field| field.key)) != JsonValue.sort(files.map(|file| file.name)) {
			return invalid
		}
		for file in files {
			record = recorded.find_first(|field| field.key == file.name).map_ok(|field| field.value) ?? JsonValue.object([])
			if JsonValue.sort(JsonValue.keys(record)) != ["sha256", "size"] or JsonValue.get_text(record, "sha256") != Ok(file.sha256) or JsonValue.integer(JsonValue.get(record, "size") ?? JsonValue.object([])) != Ok(I64.from_str(file.size.to_str()) ?? -1) {
				return Err("Linker-input integrity failure: ${file.name}")
			}
		}
		Ok(version)
	}

	## The aggregate archive's SPDX document.
	inputs_sbom : { version : Str, commit : Str, epoch : I64, archive_sha256 : Str, files : List({ name : Str, sha256 : Str }), sources : JsonValue } -> JsonValue
	inputs_sbom = |s| {
		tool = "Tool: roc-platform-template-zig-linker-input-builder"
		files = sorted_files(s.files)
		JsonValue.object([
			("spdxVersion", JsonValue.text("SPDX-2.3")),
			("dataLicense", JsonValue.text("CC0-1.0")),
			("SPDXID", JsonValue.text("SPDXRef-DOCUMENT")),
			("name", JsonValue.text("roc-zig-linker-inputs-${s.version}")),
			("documentNamespace", JsonValue.text("https://spdx.org/spdxdocs/roc-zig-linker-inputs-${s.archive_sha256}")),
			("creationInfo", creation(s.epoch, tool)),
			(
				"packages",
				JsonValue.array([
					JsonValue.object([
						("SPDXID", JsonValue.text("SPDXRef-inputs")),
						("name", JsonValue.text("roc-zig-linker-inputs")),
						("versionInfo", JsonValue.text(s.version)),
						("downloadLocation", JsonValue.text("NOASSERTION")),
						("filesAnalyzed", Boolean(Bool.False)),
						("licenseConcluded", JsonValue.text("NOASSERTION")),
						("licenseDeclared", JsonValue.text("NOASSERTION")),
						("copyrightText", JsonValue.text("NOASSERTION")),
						checksums(s.archive_sha256),
					]),
				]),
			),
			("files", JsonValue.array(files.map_with_index(spdx_file))),
			("relationships", JsonValue.array([relationship("SPDXRef-DOCUMENT", "DESCRIBES", "SPDXRef-inputs")].concat(files.map_with_index(|_, index| relationship("SPDXRef-inputs", "CONTAINS", "SPDXRef-file-${index.to_str()}"))))),
			(
				"annotations",
				JsonValue.array([
					JsonValue.object([
						("annotationDate", JsonValue.text(LinkInputs.utc(s.epoch))),
						("annotationType", JsonValue.text("OTHER")),
						("annotator", JsonValue.text(tool)),
						("comment", JsonValue.text(JsonValue.spaced(JsonValue.object([("source_commit", JsonValue.text(s.commit)), ("sources", s.sources)])))),
					]),
				]),
			),
		])
	}

	## The release `dependency.json` published beside the aggregate archive.
	release_dependency : { version : Str, zig_version : Str, commit : Str, fingerprint : Str, assets : List({ name : Str, sha256 : Str, size : U64, role : Str }) } -> JsonValue
	release_dependency = |r|
		JsonValue.object([
			("schema_version", JsonValue.number(1)),
			("release_tag", JsonValue.text("linker-inputs-v${r.version}")),
			("source", JsonValue.object([("repository", JsonValue.text("lukewilliamboswell/roc-platform-template-zig")), ("commit", JsonValue.text(r.commit)), ("ref", JsonValue.text("refs/heads/main"))])),
			("input_fingerprint", JsonValue.text(r.fingerprint)),
			("targets", JsonValue.texts(release_targets)),
			("assets", JsonValue.array(r.assets.map(|asset| JsonValue.object([("name", JsonValue.text(asset.name)), ("sha256", JsonValue.text(asset.sha256)), ("size", size(asset.size)), ("role", JsonValue.text(asset.role))])))),
			("dependencies", JsonValue.array([JsonValue.object([("name", JsonValue.text("zig")), ("version", JsonValue.text(r.zig_version))])])),
			("license_summary", JsonValue.text("MIT and NOASSERTION; see SPDX and licenses in archive")),
		])

	## The identity of the committed producer inputs: SHA-256 over one
	## `path NUL blob LF` record per input, in order.
	producer_fingerprint : List({ name : Str, blob : Str }) -> Try(Str, Str)
	producer_fingerprint = |records| {
		for record in records {
			if !is_hex(record.blob, 40) {
				return Err("uncommitted producer input: ${record.name}")
			}
		}
		Ok(sha256_text(Str.join_with(records.map(|record| "${record.name}\u(0000)${record.blob}\n"), "")))
	}

	## The `build-input-release.json` the trusted publisher reads: one line.
	build_input_release : { repository : Str, sha : Str, ref : Str, fingerprint : Str, asset : Str, sha256 : Str, size : U64 } -> Str
	build_input_release = |r| {
		source = JsonValue.object([
			("repository", JsonValue.text(r.repository)),
			("sha", JsonValue.text(r.sha)),
			("ref", JsonValue.text(r.ref)),
			("workflow", JsonValue.text("${r.repository}/.github/workflows/linker-inputs.yml")),
			("input_fingerprint", JsonValue.text(r.fingerprint)),
		])
		all = JsonValue.object([("asset", JsonValue.text(r.asset)), ("sha256", JsonValue.text(r.sha256)), ("size", size(r.size))])
		"${JsonValue.compact(JsonValue.object([("schema_version", JsonValue.number(1)), ("kind", JsonValue.text("roc-zig-link-inputs")), ("source", source), ("assets", JsonValue.object([("all", all)]))]))}\n"
	}

	## A `SHA256SUMS` file, sorted by file name.
	sha256sums : List({ name : Str, sha256 : Str }) -> Str
	sha256sums = |files| Str.join_with(sorted_files(files).map(|file| "${file.sha256}  ${file.name}\n"), "")

	## Whether a version is `MAJOR.MINOR.PATCH` without leading zeros.
	is_version : Str -> Bool
	is_version = |version| {
		parts = Str.split_on(version, ".")
		parts.len() == 3 and parts.all(
			|part| {
				bytes = Str.to_utf8(part)
				!bytes.is_empty() and bytes.all(|b| b >= '0' and b <= '9') and (bytes.len() == 1 or bytes.first() != Ok('0'))
			},
		)
	}

	## The SHA-256 of a string's UTF-8 bytes, as lowercase hex.
	sha256 : List(U8) -> Str
	sha256 = |bytes| Crypto.SHA256.hash(bytes).to_hex()
}

sha256_text = |text| LinkInputs.sha256(Str.to_utf8(text))

is_hex : Str, U64 -> Bool
is_hex = |text, length| {
	bytes = Str.to_utf8(text)
	bytes.len() == length and bytes.all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))
}

size : U64 -> JsonValue
size = |n| JsonValue.number(I64.from_str(n.to_str()) ?? -1)

checksums = |sha| ("checksums", JsonValue.array([JsonValue.object([("algorithm", JsonValue.text("SHA256")), ("checksumValue", JsonValue.text(sha))])]))

relationship = |element, kind, related| JsonValue.object([("spdxElementId", JsonValue.text(element)), ("relationshipType", JsonValue.text(kind)), ("relatedSpdxElement", JsonValue.text(related))])

creation = |epoch, tool| JsonValue.object([("created", JsonValue.text(LinkInputs.utc(epoch))), ("creators", JsonValue.texts([tool]))])

sorted_files = |files| List.sort_with(files, |a, b| JsonValue.order(a.name, b.name))

spdx_file = |file, index|
	JsonValue.object([
		("SPDXID", JsonValue.text("SPDXRef-file-${index.to_str()}")),
		("fileName", JsonValue.text("./${file.name}")),
		checksums(file.sha256),
		("licenseConcluded", JsonValue.text("NOASSERTION")),
		("licenseInfoInFiles", JsonValue.texts(["NOASSERTION"])),
		("copyrightText", JsonValue.text("NOASSERTION")),
	])

pad : I64 -> Str
pad = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

# Sorted, without repeats.
unique : List(Str) -> List(Str)
unique = |items|
	JsonValue.sort(items).fold(
		[],
		|kept, item|
			if kept.last() == Ok(item) {
				kept
			} else {
				kept.append(item)
			},
	)

lines_of : Str -> List(Str)
lines_of = |text| Str.split_on(text, "\n").map(|line| line.drop_suffix("\r")).keep_if(|line| line != "")

words : Str -> List(Str)
words = |line| Str.split_on(line.replace_each("\t", " "), " ").keep_if(|word| word != "")

split_words : List(U8), [Between, Bare, Single, Double], List(U8), List(Str) -> Try(List(Str), Str)
split_words = |bytes, mode, word, out| {
	finish = |acc| out.append(Str.from_utf8_lossy(acc))
	match (mode, bytes) {
		(Between, []) => Ok(out)
		(Bare, []) => Ok(finish(word))
		(_, []) => Err("No closing quotation")
		(Single, ['\'', .. as rest]) => split_words(rest, Bare, word, out)
		(Single, [b, .. as rest]) => split_words(rest, Single, word.append(b), out)
		(Double, ['"', .. as rest]) => split_words(rest, Bare, word, out)
		(Double, ['\\', b, .. as rest]) if b == '"' or b == '\\' or b == '$' or b == '`' or b == '\n' => split_words(rest, Double, word.append(b), out)
		(Double, [b, .. as rest]) => split_words(rest, Double, word.append(b), out)
		(_, ['\\']) => Err("No escaped character")
		(_, ['\\', b, .. as rest]) => split_words(rest, Bare, word.append(b), out)
		(_, ['\'', .. as rest]) => split_words(rest, Single, word, out)
		(_, ['"', .. as rest]) => split_words(rest, Double, word, out)
		(Between, [b, .. as rest]) if b == ' ' or b == '\t' or b == '\n' or b == '\r' => split_words(rest, Between, word, out)
		(Bare, [b, .. as rest]) if b == ' ' or b == '\t' or b == '\n' or b == '\r' => split_words(rest, Between, [], finish(word))
		(_, [b, .. as rest]) => split_words(rest, Bare, word.append(b), out)
	}
}

expect LinkInputs.shell_split("ld.lld -o 'a b' \"c\\\"d\" e\\ f ''") == Ok(["ld.lld", "-o", "a b", "c\"d", "e f", ""])
expect LinkInputs.shell_split("a 'b").is_err()
expect LinkInputs.absolute("/w", "zc/o/1/../2/./libc.a") == "/w/zc/o/2/libc.a" and LinkInputs.absolute("/w", "/abs") == "/abs"

trace = "ld.lld -r -o zc/o/e/crt1.o zc/o/b/crt1.o\nld.lld --error-limit=0 -static -o probe zc/o/e/crt1.o zl/o/1/stdin.o --as-needed -L/ zc/o/9/libc.a zc/o/3/libzigc.a zc/o/6/libcompiler_rt.a\n"

expect LinkInputs.runtime_link_inputs(trace, "/w/zc") == Ok([{ name: "crt1.o", path: "/w/zc/o/e/crt1.o" }, { name: "libc.a", path: "/w/zc/o/9/libc.a" }, { name: "libzigc.a", path: "/w/zc/o/3/libzigc.a" }, { name: "libcompiler_rt.a", path: "/w/zc/o/6/libcompiler_rt.a" }])
expect LinkInputs.runtime_link_inputs(trace.replace_each("zc/o/9/libc.a", "/usr/lib/libc.a"), "/w/zc").is_err()
expect LinkInputs.runtime_link_inputs(trace.replace_each("zl/o/1/stdin.o", "/usr/lib/libm.a"), "/w/zc").is_err()
expect LinkInputs.runtime_link_inputs(trace.replace_each("zc/o/6/libcompiler_rt.a", ""), "/w/zc").is_err()
expect LinkInputs.runtime_link_inputs("${trace}${trace}", "/w/zc").is_err()

expect LinkInputs.windows_link_inputs("noise\nlld-link -OUT:p.exe zc/o/1/kernel32.lib 'zc/o/2 x/ntdll.lib' /abs/user32.lib\n", ["ntdll.lib", "kernel32.lib", "user32.lib"], "/w") == Ok([{ name: "ntdll.lib", path: "/w/zc/o/2 x/ntdll.lib" }, { name: "kernel32.lib", path: "/w/zc/o/1/kernel32.lib" }, { name: "user32.lib", path: "/abs/user32.lib" }])
expect LinkInputs.windows_link_inputs("lld-link zc/o/1/kernel32.lib\n", ["ntdll.lib", "kernel32.lib", "advapi32.lib"], "/w") == Err("Incomplete Windows linker inputs: advapi32.lib, ntdll.lib")

nm_listing = "\nhost.o:\n                 U _malloc\n                 U _roc_main\n                 U _helper\n0000000000000010 T _helper\n0000000000000020 T _roc_entry\n                 U _free\n"

expect LinkInputs.unresolved(nm_listing) == ["_free", "_malloc", "_roc_main"]
expect LinkInputs.audit_macos([nm_listing, "                 U _write\n"], ["_free", "_malloc", "_write"]) == Ok({})
expect LinkInputs.audit_macos([nm_listing], ["_free", "_open"]) == Err("macOS interface catalog differs from host audit; missing=[\"_malloc\"], extra=[\"_open\"]")

catalog = JsonValue.object([("schema", JsonValue.number(1)), ("library", JsonValue.text("libSystem")), ("install_name", JsonValue.text("/usr/lib/libSystem.B.dylib")), ("targets", JsonValue.texts(["x86_64-macos", "arm64-macos"])), ("symbols", JsonValue.texts(["_a", "_b"])), ("evidence", JsonValue.object([]))])

expect LinkInputs.macos_stub(catalog) == Ok("--- !tapi-tbd\ntbd-version:     4\ntargets:         [ x86_64-macos, arm64-macos ]\ninstall-name:    /usr/lib/libSystem.B.dylib\nexports:\n  - targets:         [ x86_64-macos, arm64-macos ]\n    symbols:\n      - '_a'\n      - '_b'\n...\n")
expect LinkInputs.macos_stub(JsonValue.object([("schema", JsonValue.number(1))])).is_err()
expect LinkInputs.macos_symbols(JsonValue.parse(JsonValue.render(catalog).replace_each("\"_a\",\n    \"_b\"", "\"_b\",\n    \"_a\"")) ?? catalog) == Err("macOS symbols must be unique and sorted")

expect LinkInputs.valid_windows_header("x64win: { inputs: [\n \"host.lib\",\n app,\n \"msvc_runtime.lib\",\n${Str.join_with(LinkInputs.windows_imports.map(|name| " \"${name}\",\n"), "")}] }")
expect !LinkInputs.valid_windows_header("x64win: { inputs: [\"app\", \"host.lib\"] }")

expect LinkInputs.utc(0) == "1970-01-01T00:00:00Z"
expect LinkInputs.utc(1_791_115_200) == "2026-10-04T12:00:00Z"
expect LinkInputs.utc(951_782_399) == "2000-02-28T23:59:59Z"
expect LinkInputs.utc(951_868_800) == "2000-03-01T00:00:00Z"

expect LinkInputs.archive_order(["targets/b", "dependency.json", "licenses/Zig.txt", "targets/a"]) == Ok(["dependency.json", "licenses/Zig.txt", "targets/a", "targets/b"])
expect ["../escape", "/absolute", "C:/escape", "a\\b", "a//b", "./a", ""].all(|name| LinkInputs.archive_order([name]).is_err())
expect LinkInputs.archive_order(["a", "a"]).is_err()

listing = "-rw-r--r-- 0/0      12 1970-01-01 00:00 targets/x64mac/libSystem.tbd\ndrwxr-xr-x 0/0       0 1970-01-01 00:00 targets/\n"

expect LinkInputs.tar_entries(listing, 100) == Ok([{ name: "targets/x64mac/libSystem.tbd", directory: Bool.False, size: 12 }, { name: "targets", directory: Bool.True, size: 0 }])
expect LinkInputs.tar_entries(listing, 5).is_err()
expect LinkInputs.tar_entries("lrwxrwxrwx 0/0 0 1970-01-01 00:00 link -> /etc/passwd\n", 100).is_err()
expect LinkInputs.tar_entries("hrw-r--r-- 0/0 0 1970-01-01 00:00 a\n", 100).is_err()
expect LinkInputs.tar_entries("-rw-r--r-- 0/0 0 1970-01-01 00:00 ../escape\n", 100).is_err()
expect LinkInputs.tar_entries("-rw-r--r-- 0/0 0 1970-01-01 00:00 a\n-rw-r--r-- 0/0 0 1970-01-01 00:00 a\n", 100).is_err()
expect LinkInputs.runtime_listing(Str.join_with(LinkInputs.runtime_members.map(|name| "-rw-r--r-- 0/0 1 1970-01-01 00:00 ${name}\n"), "")) == Ok({})
expect LinkInputs.runtime_listing(Str.join_with(LinkInputs.runtime_members.drop_first(1).map(|name| "-rw-r--r-- 0/0 1 1970-01-01 00:00 ${name}\n"), "")).is_err()

stub_sha = LinkInputs.sha256(Str.to_utf8("stub"))

inputs = [{ name: "targets/x64mac/libSystem.tbd", sha256: stub_sha, size: 4 }]

dependency = JsonValue.render(LinkInputs.inputs_manifest({ version: "1.0.0", commit: Str.repeat("a", 40), fingerprint: Str.repeat("b", 64), files: inputs }))

expect LinkInputs.verify_inputs(dependency, inputs) == Ok("1.0.0")
expect LinkInputs.verify_inputs(dependency, [{ name: "targets/x64mac/libSystem.tbd", sha256: LinkInputs.sha256(Str.to_utf8("tampered")), size: 8 }]) == Err("Linker-input integrity failure: targets/x64mac/libSystem.tbd")
expect LinkInputs.verify_inputs(dependency, []).is_err()
expect LinkInputs.verify_inputs(dependency.replace_each("1.0.0", "01.0.0"), inputs).is_err()
expect dependency.contains("\"size\": 4") and dependency.contains("\"schema\": 1")

expect LinkInputs.sha256(Str.to_utf8("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
expect LinkInputs.sha256sums([{ name: "b", sha256: "2" }, { name: "a", sha256: "1" }]) == "1  a\n2  b\n"
expect LinkInputs.producer_fingerprint([{ name: "a", blob: Str.repeat("0", 40) }]) == Ok(LinkInputs.sha256(Str.to_utf8("a\u(0000)${Str.repeat("0", 40)}\n")))
expect LinkInputs.producer_fingerprint([{ name: "a", blob: "fatal: path 'a' does not exist" }]).is_err()
expect LinkInputs.producer_inputs.contains("scripts/build_link_inputs.roc") and !LinkInputs.producer_inputs.any(|name| name.ends_with(".py"))

expect LinkInputs.build_input_release({ repository: "o/r", sha: "s", ref: "refs/pull/1/merge", fingerprint: "f", asset: "link-inputs-all.tar", sha256: "d", size: 10 }) == "{\"assets\":{\"all\":{\"asset\":\"link-inputs-all.tar\",\"sha256\":\"d\",\"size\":10}},\"kind\":\"roc-zig-link-inputs\",\"schema_version\":1,\"source\":{\"input_fingerprint\":\"f\",\"ref\":\"refs/pull/1/merge\",\"repository\":\"o/r\",\"sha\":\"s\",\"workflow\":\"o/r/.github/workflows/linker-inputs.yml\"}}\n"

lock = JsonValue.parse("{\"zig_version\": \"0.17.0\", \"musl_version\": \"1.2.5\", \"toolchains\": {\"x86_64-linux\": {\"url\": \"https://z/zig.tar.xz\", \"sha256\": \"c\"}}, \"objcopy\": {\"version\": \"18.1.3\", \"source\": \"https://llvm\"}}") ?? JsonValue.object([])

runtime_sbom_text = LinkInputs.runtime_sbom({ version: "1.0.0", lock, builder: "x86_64-linux", files: [{ name: "manifest.json", sha256: "m" }, { name: "licenses/Zig.txt", sha256: "z" }], archive_sha256: "a", epoch: 0 }).map_ok(JsonValue.render) ?? ""

expect runtime_sbom_text.contains("\"documentNamespace\": \"https://spdx.org/spdxdocs/roc-runtime-a\"")
expect runtime_sbom_text.contains("\"fileName\": \"./licenses/Zig.txt\"") and runtime_sbom_text.contains("\"SPDXRef-file-1\"") and !runtime_sbom_text.contains("\"SPDXRef-file-2\"")
expect runtime_sbom_text.contains("\"downloadLocation\": \"https://z/zig.tar.xz\"") and runtime_sbom_text.contains("\"licenseDeclared\": \"Apache-2.0 WITH LLVM-exception\"")
expect LinkInputs.runtime_sbom({ version: "1.0.0", lock, builder: "aarch64-linux", files: [], archive_sha256: "a", epoch: 0 }).is_err()

inputs_sbom_text = JsonValue.render(LinkInputs.inputs_sbom({ version: "1.1.0", commit: "c", epoch: 0, archive_sha256: "a", files: [{ name: "b", sha256: "2" }, { name: "a", sha256: "1" }], sources: JsonValue.object([("version", JsonValue.text("1.1.0"))]) }))

expect inputs_sbom_text.contains("\"comment\": \"{\\\"source_commit\\\": \\\"c\\\", \\\"sources\\\": {\\\"version\\\": \\\"1.1.0\\\"}}\"")
expect inputs_sbom_text.contains("\"SPDXID\": \"SPDXRef-file-0\",\n      \"checksums\": [\n        {\n          \"algorithm\": \"SHA256\",\n          \"checksumValue\": \"1\"")
expect inputs_sbom_text.contains("\"created\": \"1970-01-01T00:00:00Z\"")
