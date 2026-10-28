## Pure decisions for a platform release: its version, asset names and URLs,
## the one line an archived example changes, and the documents it publishes.
Release := [].{

	## The relative path every repository example names the platform by.
	platform_source : Str
	platform_source = "../../platform/main.roc"

	## The version a pull request's dry run releases. Roc rejects `0.0.0` in a
	## package URL.
	dry_run : Str
	dry_run = "0.0.1-dryrun"

	## A plain `MAJOR.MINOR.PATCH` release, or the dry run.
	valid_version : Str -> Bool
	valid_version = |version|
		version == dry_run or match version.split_on(".") {
			[major, minor, patch] => [major, minor, patch].all(number)
			_ => Bool.False
		}

	examples_archive : Str, Str -> Str
	examples_archive = |name, version| "${name}-examples-${version}.zip"

	bundle_url : Str, Str, Str -> Str
	bundle_url = |repository, version, bundle| "https://github.com/${repository}/releases/download/${version}/${bundle}"

	## An archived example's source: the same file with the platform named by
	## its release URL. The relative platform path must appear exactly once.
	with_platform : Str, Str -> Try(Str, Str)
	with_platform = |source, url|
		match source.split_on("platform \"${platform_source}\"") {
			[before, after] => Ok("${before}platform \"${url}\"${after}")
			_ => Err("must name the platform as \"${platform_source}\" exactly once")
		}

	readme : Str, Str, Str -> Str
	readme = |name, version, url|
		Str.join_with(
			[
				"# ${name} ${version} examples",
				"",
				"These examples depend on the platform released as ${name} ${version}:",
				"",
				"    ${url}",
				"",
				"Run one with the latest Roc nightly, for example:",
				"",
				"    roc examples/hello_world/main.roc",
				"",
				"`spec.json` records what each example prints; it is the suite the",
				"release was tested with.",
				"",
			],
			"\n",
		)

	## JSON text built from already rendered values, with two-space
	## indentation; an object keeps its keys in the order given.
	object : List((Str, Str)) -> Str
	object = |fields| if (fields.is_empty()) "{}" else "{\n${Str.join_with(fields.map(|(key, value)| "  ${text(key)}: ${nested(value)}"), ",\n")}\n}"

	array : List(Str) -> Str
	array = |items| if (items.is_empty()) "[]" else "[\n${Str.join_with(items.map(|item| "  ${nested(item)}"), ",\n")}\n]"

	text : Str -> Str
	text = |value| Json.to_str(value)

	boolean : Bool -> Str
	boolean = |value| if (value) "true" else "false"

	## One SPDX file entry.
	spdx_file : Str, Str, Str -> Str
	spdx_file = |ident, name, sha256| object([
		("SPDXID", text(ident)),
		("fileName", text("./${name}")),
		("checksums", array([sha256_checksum(sha256)])),
		("licenseConcluded", text("NOASSERTION")),
		("licenseInfoInFiles", array([text("NOASSERTION")])),
		("copyrightText", text("NOASSERTION")),
	])

	spdx_package : { ident : Str, name : Str, version : Str, location : Str, sha256 : Str } -> Str
	spdx_package = |p| object(
		[
			("SPDXID", text("SPDXRef-${p.ident}")),
			("name", text(p.name)),
			("versionInfo", text(p.version)),
			("downloadLocation", text(p.location)),
			("filesAnalyzed", boolean(!p.sha256.is_empty() and p.ident == "inputs")),
			("licenseConcluded", text("NOASSERTION")),
			("licenseDeclared", text("NOASSERTION")),
			("copyrightText", text("NOASSERTION")),
		].concat(if (p.sha256.is_empty()) [] else [("checksums", array([sha256_checksum(p.sha256)]))]),
	)

	relationship : Str, Str, Str -> Str
	relationship = |from, kind, to| object([("spdxElementId", text(from)), ("relationshipType", text(kind)), ("relatedSpdxElement", text(to))])

	## The platform's SPDX document: the bundle, the linker-input release it
	## depends on with every file it contains, and the tools that built it.
	Sbom : {
		name : Str,
		commit : Str,
		created : Str,
		archive_sha256 : Str,
		inputs : { version : Str, url : Str, sha256 : Str, files : List({ name : Str, sha256 : Str }) },
		platform_files : List({ name : Str, sha256 : Str }),
		zig : Str,
		roc : Str,
	}

	sbom : Sbom -> Str
	sbom = |s| {
		input_files = s.inputs.files.map_with_index(|file, index| (file, "SPDXRef-input-file-${index.to_str()}"))
		platform_files = s.platform_files.map_with_index(|file, index| (file, "SPDXRef-platform-file-${index.to_str()}"))
		tools = [("platform-zig", "Zig host compiler", s.zig), ("roc", "Roc bundler", s.roc)]
		found_packages = [
			spdx_package({ ident: "inputs", name: "roc-zig-link-inputs", version: s.inputs.version, location: s.inputs.url, sha256: s.inputs.sha256 }),
			spdx_package({ ident: "platform", name: s.name, version: s.commit, location: "NOASSERTION", sha256: s.archive_sha256 }),
		].concat(tools.map(|(ident, name, version)| spdx_package({ ident, name, version, location: "NOASSERTION", sha256: "" })))
		relationships = [
			relationship("SPDXRef-DOCUMENT", "DESCRIBES", "SPDXRef-platform"),
			relationship("SPDXRef-platform", "DEPENDS_ON", "SPDXRef-inputs"),
		]
			.concat(input_files.map(|(_, ident)| relationship("SPDXRef-inputs", "CONTAINS", ident)))
			.concat(platform_files.map(|(_, ident)| relationship("SPDXRef-platform", "CONTAINS", ident)))
			.concat(tools.map(|(ident, _, _)| relationship("SPDXRef-${ident}", "BUILD_TOOL_OF", "SPDXRef-platform")))
		files = input_files.concat(platform_files).map(|(file, ident)| spdx_file(ident, file.name, file.sha256))
		"${
			object([
				("spdxVersion", text("SPDX-2.3")),
				("dataLicense", text("CC0-1.0")),
				("SPDXID", text("SPDXRef-DOCUMENT")),
				("name", text(s.name)),
				("documentNamespace", text("https://spdx.org/spdxdocs/roc-platform-${s.archive_sha256}")),
				("creationInfo", object([("created", text(s.created)), ("creators", array([text("Tool: ${s.name}-sbom")]))])),
				("packages", array(found_packages)),
				("files", array(files)),
				("relationships", array(relationships)),
			])
		}\n"
	}
}

number : Str -> Bool
number = |part| {
	bytes = part.to_utf8()
	!bytes.is_empty() and bytes.all(|byte| byte >= '0' and byte <= '9') and (bytes.len() == 1 or bytes.first() != Ok('0'))
}

sha256_checksum : Str -> Str
sha256_checksum = |sha256| Release.object([("algorithm", Release.text("SHA256")), ("checksumValue", Release.text(sha256))])

# A rendered value placed one level deeper.
nested : Str -> Str
nested = |value| value.replace_each("\n", "\n  ")

expect Release.valid_version("1.2.0") and Release.valid_version("0.0.1-dryrun") and Release.valid_version("10.0.3")
expect !Release.valid_version("1.2") and !Release.valid_version("v1.2.0") and !Release.valid_version("01.2.0") and !Release.valid_version("1.2.0-rc1")
expect Release.with_platform("app [main!] { pf: platform \"../../platform/main.roc\" }\n", "https://x/y.tar.zst") == Ok("app [main!] { pf: platform \"https://x/y.tar.zst\" }\n")
expect Release.with_platform("app [main!] { pf: platform \"other\" }", "u").is_err()
expect Release.examples_archive("p", "1.0.0") == "p-examples-1.0.0.zip"
expect Release.object([("b", "1"), ("a", Release.array([Release.text("x\"y"), Release.boolean(Bool.True)]))]) == "{\n  \"b\": 1,\n  \"a\": [\n    \"x\\\"y\",\n    true\n  ]\n}"
expect Release.object([("e", Release.array([])), ("o", Release.object([]))]) == "{\n  \"e\": [],\n  \"o\": {}\n}"
expect Release.sbom({ name: "p", commit: "c", created: "t", archive_sha256: "a", inputs: { version: "1.1.0", url: "u", sha256: "s", files: [{ name: "f", sha256: "1" }] }, platform_files: [{ name: "g", sha256: "2" }], zig: "0.17.0", roc: "nightly" }).contains("\"fileName\": \"./g\"")
