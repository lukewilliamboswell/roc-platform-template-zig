## Platform-specific SPDX document.
Sbom := [].{

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
	Document : {
		name : Str,
		commit : Str,
		created : Str,
		archive_sha256 : Str,
		inputs : { version : Str, url : Str, sha256 : Str, files : List({ name : Str, sha256 : Str }) },
		platform_files : List({ name : Str, sha256 : Str }),
		zig : Str,
		roc : Str,
	}

	sbom : Document -> Str
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

sha256_checksum : Str -> Str
sha256_checksum = |sha256| Sbom.object([("algorithm", Sbom.text("SHA256")), ("checksumValue", Sbom.text(sha256))])

# A rendered value placed one level deeper.
nested : Str -> Str
nested = |value| value.replace_each("\n", "\n  ")

expect Sbom.sbom({ name: "p", commit: "c", created: "t", archive_sha256: "a", inputs: { version: "1.1.0", url: "u", sha256: "s", files: [{ name: "f", sha256: "1" }] }, platform_files: [{ name: "g", sha256: "2" }], zig: "0.17.0", roc: "nightly" }).contains("SPDXRef-platform-file-0")
