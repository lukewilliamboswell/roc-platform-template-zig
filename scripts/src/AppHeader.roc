# Vendored from lukewilliamboswell/roc-automation, formatted by roc-stable, at
# a25b5129340b9b2ad1744d20330b8ee4d38a1849/scripts/src/AppHeader.roc.
## Admit the canonical application header subset used by published examples.
## Comments and string contents never become fields. Unsupported or ambiguous
## header syntax fails closed; the compiler still checks the application itself.
## An application names at most one platform: the compiler supplies a default
## platform to an application that names none.
AppHeader := [].{
	valid = |source, dependencies| {
		tokens = match lex(Str.to_utf8(source), [], []) {
			Ok(value) => value
			Err(_) => return Bool.False
		}
		match tokens {
			[Word("app"), Mark('['), .. as rest] => entrypoints(rest, dependencies)
			_ => Bool.False
		}
	}

	lex = |bytes, word, tokens| match bytes {
		[] => Err(Invalid)
		[byte, .. as rest] if (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_' => lex(rest, word.append(byte), tokens)
		_ if !word.is_empty() => lex(bytes, [], tokens.append(Word(Str.from_utf8_lossy(word))))
		[byte, .. as rest] if [9, 10, 13, 32].contains(byte) => lex(rest, [], tokens)
		['#', .. as rest] => comment(rest, tokens)
		['"', .. as rest] => quoted(rest, [], tokens)
		['}', ..] => Ok(tokens.append(Mark('}')))
		[byte, .. as rest] if ['[', ']', '{', ':', ',', '!'].contains(byte) => lex(rest, [], tokens.append(Mark(byte)))
		_ => Err(Invalid)
	}
	comment = |bytes, tokens| match bytes {
		[10, .. as rest] => lex(rest, [], tokens)
		[_, .. as rest] => comment(rest, tokens)
		[] => Err(Invalid)
	}
	quoted = |bytes, value, tokens| match bytes {
		['"', .. as rest] => lex(rest, [], tokens.append(Text(Str.from_utf8_lossy(value))))
		[byte, .. as rest] if byte >= 32 and byte != '\\' => quoted(rest, value.append(byte), tokens)
		_ => Err(Invalid)
	}
	entrypoints = |tokens, dependencies| match tokens {
		[Mark(']'), Mark('{'), .. as rest] => bindings(rest, dependencies, [], Bool.False, 0)
		[Word(_), .. as rest] => entrypoint_end(rest, dependencies)
		_ => Bool.False
	}
	entrypoint_end = |tokens, dependencies| match tokens {
		[Mark('!'), .. as rest] => entrypoint_separator(rest, dependencies)
		_ => entrypoint_separator(tokens, dependencies)
	}
	entrypoint_separator = |tokens, dependencies| match tokens {
		[Mark(','), .. as rest] => entrypoints(rest, dependencies)
		[Mark(']'), Mark('{'), .. as rest] => bindings(rest, dependencies, [], Bool.False, 0)
		_ => Bool.False
	}
	bindings = |tokens, dependencies, names, found, platforms| match tokens {
		[Mark('}')] => found and platforms <= 1
		[Word(name), Mark(':'), .. as rest] if name != "roc" and !names.contains(name) => match rest {
			[Word("platform"), Text(url), .. as after] => separator(after, dependencies, names.append(name), found or dependencies.contains(url), platforms + 1)
			[Text(url), .. as after] => separator(after, dependencies, names.append(name), found or dependencies.contains(url), platforms)
			_ => Bool.False
		}
		_ => Bool.False
	}
	separator = |tokens, dependencies, names, found, platforms| match tokens {
		[Mark(','), .. as rest] => bindings(rest, dependencies, names, found, platforms)
		[Mark('}')] => found and platforms <= 1
		_ => Bool.False
	}

	## Every `name: "source"` field of an app or package header, in order, with
	## whether it is the platform. Fails closed on anything the lexer rejects.
	fields : Str -> Try(List({ name : Str, source : Str, is_platform : Bool }), [Invalid])
	fields = |source| {
		tokens = lex(Str.to_utf8(source), [], [])?
		match tokens {
			[Word("app"), .. as rest] => after_brace(rest, [])
			[Word("package"), .. as rest] => after_brace(rest, [])
			_ => Err(Invalid)
		}
	}
	after_brace = |tokens, found| match tokens {
		[Mark('{'), .. as rest] => field_list(rest, found)
		[_, .. as rest] => after_brace(rest, found)
		[] => Err(Invalid)
	}
	field_list = |tokens, found| match tokens {
		[Mark('}')] => Ok(found)
		[Mark(','), .. as rest] => field_list(rest, found)
		[Word(name), Mark(':'), Word("platform"), Text(source), .. as rest] => field_list(rest, found.append({ name, source, is_platform: Bool.True }))
		[Word(name), Mark(':'), Text(source), .. as rest] => field_list(rest, found.append({ name, source, is_platform: Bool.False }))
		_ => Err(Invalid)
	}

	## Whether a header declares a `roc` compiler pin.
	has_roc_pin : Str -> Bool
	has_roc_pin = |source| (fields(source) ?? []).any(|field| field.name == "roc")

	## Whether `source` is an application: a `.roc` file under examples/
	## without an `app` header is a module the examples share.
	is_app : Str -> Bool
	is_app = |source|
		match lex(Str.to_utf8(source), [], []) {
			Ok([Word("app"), ..]) => Bool.True
			_ => Bool.False
		}

	## The field whose declared source is `declared`, such as the shorthand an
	## example gives the package at `../package/main.roc`.
	shorthand_of : Str, Str -> Try(Str, [MissingDependency(Str), DuplicateDependency(Str), Invalid])
	shorthand_of = |source, declared| {
		declared_fields = fields(source)?
		match List.keep_if(declared_fields, |field| field.source == declared) {
			[field] => Ok(field.name)
			[] => Err(MissingDependency(declared))
			_ => Err(DuplicateDependency(declared))
		}
	}

	## The same source with the field `shorthand`, currently `declared`,
	## pointing at `replacement`. Nothing else changes. The header must be
	## formatted by `roc fmt`, so that `shorthand: "declared"` is found inside
	## the header; the body may mention the same text afterwards.
	with_dependency : Str, Str, Str, Str -> Try(Str, [UnformattedDependency(Str)])
	with_dependency = |source, shorthand, declared, replacement| {
		needle = "${shorthand}: \"${declared}\""
		match Str.split_first(source, needle) {
			Ok({ before, after }) if opens_header(before) => Ok("${before}${shorthand}: \"${replacement}\"${after}")
			_ => Err(UnformattedDependency(shorthand))
		}
	}
}

# Whether `text` ends inside the braces of an app or package header.
opens_header = |text| {
	header = header_onwards(Str.split_on(text, "\n"))
	header.contains("{") and !header.contains("}")
}

header_onwards = |lines|
	match lines {
		[line, ..] if line.starts_with("app ") or line.starts_with("package ") => Str.join_with(lines, "\n")
		[_, .. as rest] => header_onwards(rest)
		[] => ""
	}

url = "https://github.com/o/pkg/releases/download/1.0.0/hash.tar.zst"
expect AppHeader.valid("app [main!] { pf: platform \"${url}\" }", [url])
expect AppHeader.valid("# header comment\napp [main!, other] {\n# ignored } \"bogus\"\n cli: platform \"third-party\", pkg: \"${url}\",\n}", [url])
expect !AppHeader.valid("app [main!] { # \"${url}\"\n pf: platform \"other\" }", [url])
expect !AppHeader.valid("app [main!] { pf: platform \"other\" }\nvalue = \"${url}\"", [url])
expect !AppHeader.valid("app [main!] { pf: platform \"${url}\", roc\n:\n\"nightly-x\" }", [url])
expect !AppHeader.valid("app [main!] { pf: platform \"${url}\", pf: \"other\" }", [url])
expect !AppHeader.valid("app [main!] { pf: platform \"other\", ignored: [\"${url}\"] }", [url])
expect !AppHeader.valid("app [main!] { pf: platform \"${url}\"", [url])
expect !AppHeader.valid("app [main!] { pf: platform \"other\", pkg: \"${url}\" extra }", [url])
expect !AppHeader.valid("app [main!] { pf: platform \"other\", pkg: \"${url}\" roc: \"nightly\" }", [url])
expect AppHeader.valid("app [main!] { time: \"${url}\" }", [url])
expect !AppHeader.valid("app [main!] { pf: platform \"${url}\", other: platform \"second\" }", [url])

example = "app [main!] {\n\tansi: \"../package/main.roc\",\n\tpf: platform \"https://example.com/cli.tar.zst\",\n}\n\nmain! = |_| { ansi: \"../package/main.roc\" }\n"

expect AppHeader.fields(example) == Ok([{ name: "ansi", source: "../package/main.roc", is_platform: Bool.False }, { name: "pf", source: "https://example.com/cli.tar.zst", is_platform: Bool.True }])
expect AppHeader.fields("package [A, B] { roc: \"nightly-1\" }\n") == Ok([{ name: "roc", source: "nightly-1", is_platform: Bool.False }])
expect AppHeader.fields("Files := [].{\n\tpin = { roc: \"nightly\" }\n}\n").is_err()
expect AppHeader.is_app(example) and AppHeader.is_app("# comment\napp [main!] { pf: platform \"x\" }\n")
expect !AppHeader.is_app("## Shared by the examples.\nRender := [].{\n\tto_json = |x| x\n}\n") and !AppHeader.is_app("package [A] {}\n")
expect AppHeader.has_roc_pin("app [main!] { ansi: \"../package/main.roc\", roc: \"nightly-2026-10-09-258ab27\" }\n")
expect !AppHeader.has_roc_pin(example) and !AppHeader.has_roc_pin("app [main!] { heroc: \"https://example.com/roc: x.tar.zst\" }\n")
expect AppHeader.shorthand_of(example, "../package/main.roc") == Ok("ansi")
expect AppHeader.shorthand_of(example, "../other/main.roc") == Err(MissingDependency("../other/main.roc"))
expect AppHeader.shorthand_of("app [main!] { a: \"x\", b: \"x\", pf: platform \"p\" }", "x") == Err(DuplicateDependency("x"))
expect AppHeader.with_dependency(example, "ansi", "../package/main.roc", "https://example.com/abc.tar.zst") == Ok("app [main!] {\n\tansi: \"https://example.com/abc.tar.zst\",\n\tpf: platform \"https://example.com/cli.tar.zst\",\n}\n\nmain! = |_| { ansi: \"../package/main.roc\" }\n")
expect AppHeader.with_dependency("app [main!] { ansi : \"../package/main.roc\" }\n", "ansi", "../package/main.roc", "x") == Err(UnformattedDependency("ansi"))
expect AppHeader.with_dependency("# ansi: \"x\"\napp [main!] { ansi: \"x\" }\n", "ansi", "x", "y") == Err(UnformattedDependency("ansi"))
