#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst",
	roc: "nightly-2026-10-09-258ab27",
}

import cli.Cmd
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout
main! = |args| {
	if !args.is_empty() {
		return Err(Exit(2))
	}
	source = Path.read_utf8!(Path.utf8("tests/spec.json")).map_err(|_| Exit(1))?
	parsed : Try({ apps : List({ path : Str }) }, _)
	parsed = Json.parse(source)
	suite = parsed.map_err(|_| Exit(1))?
	for example in suite.apps {
		code = Cmd.new_str("roc").args_str(["test", example.path, "--no-cache"]).exec_exit_code!().map_err(|_| Exit(1))?
		if code != 0 {
			return Err(Exit(code))
		}
	}
	Ok({})
}
