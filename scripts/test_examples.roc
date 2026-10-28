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
import src/Compatibility
import src/Examples

## Test the working tree's examples against the platform source. Run from the
## repository root.
##
##   scripts/test_examples.roc               build the host, then check, build and run every example
##   scripts/test_examples.roc -- --update   record what each case prints in tests/spec.json
##   scripts/test_examples.roc -- --no-build skip `zig build` (the host is already built)
##
## Each example depends on `../../platform/main.roc` and names no compiler; the
## `roc` on PATH, the latest nightly, does the work. Every example's `expect`s
## run first with `roc test`; then the shared examples engine checks and builds
## each example once and runs its cases, comparing stdout, stderr and the exit
## code exactly. Command records are kept under `.zig-cache/test-examples/`.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	flags = args.map(OsStr.display)
	if !flags.all(|flag| flag == "--update" or flag == "--no-build") {
		_ = Stderr.line!("usage: scripts/test_examples.roc [--update] [--no-build]")
		return Err(Exit(2))
	}
	match run!(flags.contains("--update"), !flags.contains("--no-build")) {
		Ok({}) => Ok({})
		Err(message) => {
			_ = Stderr.line!("error: ${message}")
			Err(Exit(1))
		}
	}
}

spec_path = "tests/spec.json"

records = ".zig-cache/test-examples"

run! : Bool, Bool => Try({}, Str)
run! = |update, build| {
	if build {
		say!("\n== Host")?
		succeed!("zig", ["build"])?
	}
	suite = Compatibility.working_tree_suite(read!(spec_path)?)?

	say!("\n== Expects")?
	for example in suite.apps {
		succeed!("roc", ["test", example.path, "--no-cache"])?
	}

	say!("\n== Examples")?
	# Absolute, because each case runs in its example's own directory.
	cwd = Env.cwd!().map_err(|_| "cannot read the working directory")?
	directory = Path.join(cwd, records)
	_ = Path.delete_all!(directory)
	Path.create_all!(Path.join(directory, "cache")).map_err(|_| "cannot create ${records}")?
	outcome = Examples.execute!({
		compiler: "roc",
		root: Path.unix("."),
		suite,
		dependencies: ["../../platform/main.roc"],
		setup: { directory, cache: Path.join(directory, "cache"), environment: [], environment_text: "[]" },
		case_timeout_ms: 10_000,
		source: Direct,
		mode: if (update) Update else Compare,
		first_number: 1,
	})?
	match outcome.interrupted {
		None => {}
		Timeout(number) => return Err("command ${number.to_str()} timed out; see ${records}")
		OutputLimit(number) => return Err("command ${number.to_str()} exceeded the output limit; see ${records}")
	}
	if update {
		Path.write_utf8!(Path.unix(spec_path), Compatibility.render(outcome.updated)).map_err(|_| "cannot write ${spec_path}")?
		say!("Recorded ${outcome.tested.to_str()} cases in ${spec_path}")?
	}
	for failure in outcome.failures {
		_ = Stderr.line!("FAIL ${failure}")
	}
	if outcome.failed > 0 {
		return Err("${outcome.failed.to_str()} of the examples or cases failed; records are in ${records}")
	}
	say!("All examples passed (${outcome.tested.to_str()} cases, ${outcome.skipped.to_str()} skipped)")
}

read! : Str => Try(Str, Str)
read! = |path| Path.read_utf8!(Path.unix(path)).map_err(|_| "cannot read ${path}")

say! : Str => Try({}, Str)
say! = |line| Stdout.line!(line).map_err(|_| "cannot write to stdout")

## Print a command, then run it with inherited output; a non-zero exit is an error.
succeed! : Str, List(Str) => Try({}, Str)
succeed! = |program, args| {
	say!("+ ${program} ${Str.join_with(args, " ")}")?
	match Cmd.new_str(program).args_str(args).exec_exit_code!() {
		Ok(0) => Ok({})
		Ok(code) => Err("${program} ${Str.join_with(args, " ")} exited with code ${code.to_str()}")
		Err(_) => Err("could not run ${program}")
	}
}
