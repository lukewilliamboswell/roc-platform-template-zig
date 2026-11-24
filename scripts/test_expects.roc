#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-24-ff5e544",
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
		output = Cmd.new("roc").args(["test", OsStr.from_str(example.path), "--no-cache"]).inherit_stdio().run!().map_err(|_| Exit(1))?
		match output.status {
			Exited(0) => {}
			Exited(code) => return Err(Exit(code))
			Signaled(_) => return Err(Exit(1))
		}
	}
	Ok({})
}
