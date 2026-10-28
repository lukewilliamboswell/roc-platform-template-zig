# Vendored from lukewilliamboswell/roc-automation, formatted by roc-stable, at
# a25b5129340b9b2ad1744d20330b8ee4d38a1849/scripts/src/GitHub.roc.
## What the shared actions ask of GitHub through the `gh` CLI, and the checks
## they share.
##
## Nothing here has an effect. A script runs `gh` with the arguments `args`
## builds, and hands what `gh` printed to `answer`. The token is never an
## argument: `gh` reads it from `GH_TOKEN` in the environment.
GitHub := [].{

	## One REST request. `path` is below the API root, or a full `https` URL
	## for an upload. `jq` projects the response to the fields its reader
	## declares, and is empty for a response that is not JSON.
	Call : {
		method : Str,
		path : Str,
		version : Str,
		accept : Str,
		jq : Str,
		send : [Nothing, Json(Str), File(Str)],
	}

	## What one run of `gh` left behind.
	Output : { succeeded : Bool, stdout : Str, stderr : Str }

	## `Missing` is an HTTP 404, which some requests ask about on purpose.
	Answer : [Body(Str), Missing(Str), Failed(Str)]

	## The arguments of the `gh api` invocation for `call`.
	##
	## The method is always stated, because `gh api` chooses POST by itself as
	## soon as it is given a body. A JSON body is read from standard input and
	## a file is streamed from disk, so neither is ever an argument.
	args : Call -> List(Str)
	args = |call| {
		projection = if (call.jq == "") [] else ["--jq", call.jq]
		body = match call.send {
			Nothing => []
			Json(_) => ["--input", "-"]
			File(path) => ["-H", "Content-Type: application/octet-stream", "--input", path]
		}
		["api", "--method", call.method, "-H", "Accept: ${call.accept}", "-H", "X-GitHub-Api-Version: ${call.version}", call.path]
			.concat(projection)
			.concat(body)
	}

	## What to write to the standard input of that invocation.
	stdin : Call -> List(U8)
	stdin = |call|
		match call.send {
			Json(text) => Str.to_utf8(text)
			_ => []
		}

	## Classify what `gh api` printed for `call`. An error names the method,
	## the resource without its query, and the status, and never a credential:
	## `gh` prints none.
	answer : Call, Output -> Answer
	answer = |call, output| {
		problem : Try({ status : Str }, _)
		problem = Json.parse(output.stdout)
		if output.succeeded {
			Body(output.stdout)
		} else {
			match problem {
				Ok({ status: "404" }) => Missing("GitHub answered ${what(call)} with HTTP 404")
				Ok({ status }) if is_plain(status, "") => Failed("GitHub answered ${what(call)} with HTTP ${status}: ${message(output)}")
				_ => Failed(GitHub.not_run(call, first_line(output.stderr)))
			}
		}
	}

	## The error for a request that got no answer from GitHub at all.
	not_run : Call, Str -> Str
	not_run = |call, reason| "${what(call)} failed: ${GitHub.single_line(reason)}"

	## The error for an answer that was not in the shape its reader declares.
	unexpected : Call -> Str
	unexpected = |call| "GitHub's answer to ${what(call)} was not in the expected shape"

	## Whether `name` is an `owner/name` pair that is safe in a request path.
	valid_repository : Str -> Bool
	valid_repository = |name|
		match Str.split_on(name, "/") {
			[owner, repo] => is_plain(owner, "-") and !owner.starts_with("-") and count(owner) <= 39 and is_plain(repo, "-._") and count(repo) <= 100 and repo != "." and repo != ".."
			_ => Bool.False
		}

	## Whether `token` can be a credential: not empty and without whitespace.
	valid_token : Str -> Bool
	valid_token = |token| token != "" and Str.to_utf8(token).all(|byte| byte > ' ' and byte != 127)

	## Text for a workflow command such as `::error::`, which ends at the first
	## line break. Escaped, a message cannot start a second command.
	workflow_command_text : Str -> Str
	workflow_command_text = |text| Str.replace_each(Str.replace_each(Str.replace_each(text, "%", "%25"), "\r", "%0D"), "\n", "%0A")

	## `text` with every run of whitespace turned into one space.
	single_line : Str -> Str
	single_line = |text| {
		spaced = Str.replace_each(Str.replace_each(Str.replace_each(text, "\r", " "), "\n", " "), "\t", " ")
		Str.join_with(Str.split_on(spaced, " ").keep_if(|word| word != ""), " ")
	}

	## Whether `text` is non-empty and made only of ASCII letters, digits and
	## the bytes of `extra`.
	is_plain : Str, Str -> Bool
	is_plain = |text, extra| {
		extras = Str.to_utf8(extra)
		text != "" and Str.to_utf8(text).all(|byte| is_digit(byte) or (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or extras.contains(byte))
	}

	## Whether `text` is one or more ASCII digits.
	is_digits : Str -> Bool
	is_digits = |text| text != "" and Str.to_utf8(text).all(is_digit)

	## The Unicode code points of `text`.
	code_points : Str -> List(U32)
	code_points = |text| decode(Str.to_utf8(text), [])

	## The number of characters in `text`, counted as code points.
	count : Str -> U64
	count = |text| Str.to_utf8(text).count_if(|byte| byte < 128 or byte >= 192)

	## Sort text by its bytes, which does not depend on the locale.
	sort : List(Str) -> List(Str)
	sort = |values| List.sort_with(values, |left, right| compare_bytes(Str.to_utf8(left), Str.to_utf8(right)))

	## The values of `values` in their first order, each once.
	unique : List(Str) -> List(Str)
	unique = |values| values.fold([], |seen, value| if (seen.contains(value)) seen else seen.append(value))
}

# The method and resource of a request. The query is left out: it says nothing
# a reader needs, and an error message is not the place for it.
what : GitHub.Call -> Str
what = |call| {
	resource = match Str.split_first(call.path, "?") {
		Ok({ before, .. }) => before
		Err(_) => call.path
	}
	"${call.method} ${resource}"
}

# GitHub's own words for a refusal, as `gh` repeats them: `gh: Not Found (HTTP 404)`.
message : GitHub.Output -> Str
message = |output| {
	line = first_line(output.stderr).drop_prefix("gh: ")
	match Str.split_last(line, " (HTTP ") {
		Ok({ before, .. }) => GitHub.single_line(before)
		Err(_) => GitHub.single_line(line)
	}
}

first_line : Str -> Str
first_line = |text|
	match Str.split_on(text.trim(), "\n") {
		[line, ..] => line
		[] => ""
	}

is_digit = |byte| byte >= '0' and byte <= '9'

compare_bytes = |left, right|
	match (left, right) {
		([a, .. as left_rest], [b, .. as right_rest]) =>
			if (a < b) Before else if (a > b) After else compare_bytes(left_rest, right_rest)
		([], []) => Same
		([], _) => Before
		(_, []) => After
	}

# Decode UTF-8, which a `Str` always is. A lead byte says how many
# continuation bytes follow it.
decode : List(U8), List(U32) -> List(U32)
decode = |bytes, points|
	match bytes {
		[] => points
		[a, .. as rest] if a < 128 => decode(rest, points.append(a.to_u32()))
		[a, b, .. as rest] if a < 224 => decode(rest, points.append((a.to_u32() - 192) * 64 + low(b)))
		[a, b, c, .. as rest] if a < 240 => decode(rest, points.append((a.to_u32() - 224) * 4096 + low(b) * 64 + low(c)))
		[a, b, c, d, .. as rest] => decode(rest, points.append((a.to_u32() - 240) * 262144 + low(b) * 4096 + low(c) * 64 + low(d)))
		_ => points.append(65533)
	}

low : U8 -> U32
low = |byte| byte.to_u32() - 128

# Tests

listing : GitHub.Call
listing = { method: "GET", path: "repos/o/r/issues?state=open&page=2", version: "2022-11-28", accept: "application/vnd.github+json", jq: "[.[] | {number}]", send: Nothing }

creating : GitHub.Call
creating = { ..listing, method: "POST", path: "repos/o/r/issues", jq: "{number}", send: Json("{\"title\":\"t\"}") }

uploading : GitHub.Call
uploading = { ..listing, method: "POST", path: "https://uploads.github.com/repos/o/r/releases/7/assets?name=a.zip", jq: "{name}", send: File("/w/dist/a.zip") }

# The method is stated for every request, and a body never becomes an argument.
expect GitHub.args(listing) == ["api", "--method", "GET", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", "repos/o/r/issues?state=open&page=2", "--jq", "[.[] | {number}]"]
expect GitHub.args(creating) == ["api", "--method", "POST", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", "repos/o/r/issues", "--jq", "{number}", "--input", "-"]
expect GitHub.stdin(creating) == Str.to_utf8("{\"title\":\"t\"}") and GitHub.stdin(listing) == [] and GitHub.stdin(uploading) == []
expect GitHub.args(uploading) == ["api", "--method", "POST", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", "https://uploads.github.com/repos/o/r/releases/7/assets?name=a.zip", "--jq", "{name}", "-H", "Content-Type: application/octet-stream", "--input", "/w/dist/a.zip"]
expect GitHub.args({ ..listing, jq: "" }) == ["api", "--method", "GET", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", "repos/o/r/issues?state=open&page=2"]

not_found = "{\n  \"message\": \"Not Found\",\n  \"documentation_url\": \"https://docs.github.com/rest\",\n  \"status\": \"404\"\n}"

expect GitHub.answer(listing, { succeeded: Bool.True, stdout: "[]", stderr: "" }) == Body("[]")
# An absent resource is told apart from a request that failed.
expect GitHub.answer(listing, { succeeded: Bool.False, stdout: not_found, stderr: "gh: Not Found (HTTP 404)\n" }) == Missing("GitHub answered GET repos/o/r/issues with HTTP 404")
# The error names the call and the status, without the query.
expect GitHub.answer(creating, { succeeded: Bool.False, stdout: "{\"message\":\"Resource not accessible by integration\",\"status\":\"403\"}", stderr: "gh: Resource not accessible by integration (HTTP 403)\n" }) == Failed("GitHub answered POST repos/o/r/issues with HTTP 403: Resource not accessible by integration")
expect GitHub.answer(uploading, { succeeded: Bool.False, stdout: "{\"message\":\"Validation Failed\",\"status\":\"422\"}", stderr: "gh: Validation\n  Failed (HTTP 422)" }) == Failed("GitHub answered POST https://uploads.github.com/repos/o/r/releases/7/assets with HTTP 422: Validation")
# A network failure, and a response `--jq` could not read, are errors too.
expect GitHub.answer(listing, { succeeded: Bool.False, stdout: "", stderr: "error connecting to api.github.com\ncheck your internet connection\n" }) == Failed("GET repos/o/r/issues failed: error connecting to api.github.com")
expect GitHub.answer(listing, { succeeded: Bool.False, stdout: "", stderr: "expected an object but got: string (\"Not Found\")" }) == Failed("GET repos/o/r/issues failed: expected an object but got: string (\"Not Found\")")
expect GitHub.answer(listing, { succeeded: Bool.False, stdout: "<html>", stderr: "" }) == Failed("GET repos/o/r/issues failed: ")
expect GitHub.not_run(listing, "gh could not be started:\n NotFound") == "GET repos/o/r/issues failed: gh could not be started: NotFound"
expect GitHub.unexpected(listing) == "GitHub's answer to GET repos/o/r/issues was not in the expected shape"

expect GitHub.valid_repository("octo/package") and GitHub.valid_repository("o/r.s_t") and GitHub.valid_repository("lukewilliamboswell/roc-automation")
expect !GitHub.valid_repository("octo") and !GitHub.valid_repository("octo/package/extra") and !GitHub.valid_repository("octo/pack age") and !GitHub.valid_repository("")
expect !GitHub.valid_repository("../r") and !GitHub.valid_repository("o/..") and !GitHub.valid_repository("o/.") and !GitHub.valid_repository("-o/r") and !GitHub.valid_repository("o/r?x=1") and !GitHub.valid_repository("o/r\n")
expect GitHub.valid_repository("${Str.repeat("a", 39)}/${Str.repeat("b", 100)}") and !GitHub.valid_repository("${Str.repeat("a", 40)}/b") and !GitHub.valid_repository("a/${Str.repeat("b", 101)}")

expect GitHub.valid_token("ghs_secret")
expect !GitHub.valid_token("") and !GitHub.valid_token("two words") and !GitHub.valid_token("line\nbreak") and !GitHub.valid_token("tab\there") and !GitHub.valid_token(" ")

expect GitHub.workflow_command_text("50% done\r\n::notice::x") == "50%25 done%0D%0A::notice::x"
expect GitHub.single_line(" a\n\n  b\tc \r\n") == "a b c" and GitHub.single_line("") == ""

expect GitHub.is_plain("tui-menu.roc", "-._") and !GitHub.is_plain("a/b", "-._") and !GitHub.is_plain("", "-") and !GitHub.is_plain("café", "")
expect GitHub.is_digits("0123") and !GitHub.is_digits("") and !GitHub.is_digits("1a")
expect GitHub.code_points("aé€😀") == [97, 233, 8364, 128512] and GitHub.code_points("") == []
expect GitHub.count("aé€😀") == 4 and GitHub.count("") == 0
expect GitHub.sort(["b", "a/c", "a", "B", "a-b"]) == ["B", "a", "a-b", "a/c", "b"]
expect GitHub.unique(["b", "a", "b", "c", "a"]) == ["b", "a", "c"]
