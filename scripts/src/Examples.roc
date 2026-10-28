# Vendored from lukewilliamboswell/roc-automation, formatted by roc-stable, at
# a25b5129340b9b2ad1744d20330b8ee4d38a1849/scripts/src/Examples.roc.
import cli.Cmd
import cli.Env
import cli.IOErr
import cli.OsStr
import cli.Path
import cli.Stdout
import AppHeader
import Compatibility
import Loopback

## The one engine that runs an examples suite: the working tree's examples on
## a pull request, a release candidate's archived examples against the bundle
## it would publish, and a published release's examples on a nightly. Every
## compiler and example command is saved byte for byte before its result is
## judged, so a failure is diagnosed from the retained files, and compiler
## warnings are never read as a substitute for its exit status.
Examples := [].{

	## What every command needs: the directory its record and output streams
	## are saved in, the Roc package cache the compiler uses, and the public
	## test environment together with the JSON text it was read from.
	Setup : { directory : Path, cache : Path, environment : List(Compatibility.Environment), environment_text : Str }

	## How one command ended. Only the `exited` status carries a comparable
	## exit code; a timeout, output limit or I/O failure has its own.
	Ran : { status : Str, signal : I32, error : Str, code : I32, stdout : List(U8), stderr : List(U8), timed_out : Bool, limited : Bool }

	## How the examples reach the packages they depend on. `Direct` lets Roc
	## resolve each header as written. `Served` answers requests for each
	## `url` with the bytes of its `bundle` from a loopback address and adds
	## `--replace-dep` to each compiler command, so archived headers stay
	## exactly as published.
	Source : [Direct, Served(List({ url : Str, bundle : Path }))]

	## `compiler` runs every example found under `root` at the paths the suite
	## names. `dependencies` are the sources an example header must name, such
	## as the release bundle URLs or `../package/main.roc`. Commands are
	## numbered from `first_number`.
	Options : {
		compiler : Str,
		root : Path,
		suite : Compatibility.Suite,
		dependencies : List(Str),
		setup : Setup,
		case_timeout_ms : U64,
		source : Source,
		mode : [Compare, Update],
		first_number : U64,
	}

	## What a run established. `interrupted` names the command a timeout or
	## output limit stopped, in which case the counts are partial. `updated`
	## is the suite with what each case actually printed, for `Update`.
	## `failures` describe each failed build or case for a reader.
	Outcome : {
		tested : U64,
		failed : U64,
		skipped : U64,
		diagnostic_commands : U64,
		number : U64,
		interrupted : [None, Timeout(U64), OutputLimit(U64)],
		updated : Compatibility.Suite,
		failures : List(Str),
	}

	## Run one command with captured output and the test environment, with
	## the compiler's cache and tokens fixed, and no record kept.
	run_command! : Setup, List(Str), Path, List(U8), U64 => Try(Ran, Str)
	run_command! = |setup, argv, cwd, input, timeout| {
		context = context!(setup, NoServer)?
		run!(context, argv, cwd, input, timeout)
	}

	## Run one command, save its record and both output streams under
	## `number` in the setup directory, and show them even after success.
	command! : Setup, U64, List(Str), Path, List(U8), U64 => Try(Ran, Str)
	command! = |setup, number, argv, cwd, input, timeout| {
		context = context!(setup, NoServer)?
		logged!(context, number, argv, cwd, input, timeout)
	}

	## Check and build every example once, then run each of its cases.
	execute! : Options => Try(Outcome, Str)
	execute! = |options| {
		server : Try(Server, Str)
		server = match options.source {
			Direct => Ok(NoServer)
			Served(bundles) => Loopback.start!(bundles.map(|served| served.bundle)).map_ok(|active| Server(active))
		}
		context = context!(options.setup, server?)?
		ran = examples!(context, options)
		match context.server {
			Server(active) => Loopback.stop!(active)?
			NoServer => {}
		}
		ran
	}
}

# The loopback server answering the compiler's requests, if any.
Server : [NoServer, Server(Loopback.Server)]

Context : { setup : Examples.Setup, windows : Bool, server : Server }

context! : Examples.Setup, Server => Try(Context, Str)
context! = |setup, server| {
	if !Compatibility.valid_environment(setup.environment) {
		return Err("test environment overrides a reserved variable or repeats a name")
	}
	windows = match Env.platform!().os {
		WINDOWS => Bool.True
		_ => Bool.False
	}
	Ok({ setup, windows, server })
}

# Path.join constructs UTF-8 paths using '/'. External arguments and environment
# values receive the host's spelling, matching the child cwd and the compiler's
# cache-root identity rather than mixing both separator forms.
native = |context, path| Compatibility.native_path(Path.display(path), context.windows)

write! = |path, text| Path.write_utf8!(path, text).map_err(|_| "cannot write ${Path.display(path)}")

read! = |path| Path.read_utf8!(path).map_err(|_| "cannot read ${Path.display(path)}")

run! : Context, List(Str), Path, List(U8), U64 => Try(Examples.Ran, Str)
run! = |context, argv, cwd, input, timeout| {
	setup = context.setup
	match argv {
		[program, .. as arguments] => {
			base = Cmd.new(OsStr.from_str(program)).args(arguments.map(OsStr.from_str)).cwd(cwd).stdin(Bytes(input)).stdout(Capture).stderr(Capture).timeout_ms(timeout).output_limit(10_000_000).manage_tree(Bool.True)
				.env("GH_TOKEN", "").env("GITHUB_TOKEN", "").env("NO_COLOR", "1").env_str("XDG_CACHE_HOME", native(context, setup.cache)).env_str("ROC_CACHE_DIR", native(context, setup.cache))
			configured = setup.environment.fold(base, |command, entry| command.env_str(entry.name, entry.value))
			ran = match context.server {
				NoServer =>
					match configured.run!() {
						Ok(value) => Ok(value)
						Err(Timeout(partial)) => Err(Timeout(partial))
						Err(OutputLimit(partial)) => Err(OutputLimit(partial))
						Err(IO(error)) => Err(IO(error))
					}
				Server(active) => Loopback.run!(active, configured)
			}
			match ran {
				Ok(value) =>
					Ok({
						status: match value.status {
							Exited(_) => "exited"
							Signaled(_) => "signaled"
						},
						signal: match value.status {
							Signaled(signal) => signal
							Exited(_) => 0
						},
						error: "",
						code: match value.status {
							Exited(code) => code
							_ => 255
						},
						stdout: value.stdout_bytes,
						stderr: value.stderr_bytes,
						timed_out: Bool.False,
						limited: Bool.False,
					})
				Err(Timeout(partial)) => Ok({ status: "timeout", signal: 0, error: "", code: 124, stdout: partial.stdout_bytes, stderr: partial.stderr_bytes, timed_out: Bool.True, limited: Bool.False })
				Err(OutputLimit(partial)) => Ok({ status: "output-limit", signal: 0, error: "", code: 125, stdout: partial.stdout_bytes, stderr: partial.stderr_bytes, timed_out: Bool.False, limited: Bool.True })
				Err(IO(error)) => Ok({ status: "io-error", signal: 0, error: IOErr.to_str(error), code: 126, stdout: [], stderr: [], timed_out: Bool.False, limited: Bool.False })
				Err(Serve(reason)) => Err("the loopback bundle server failed: ${reason}")
			}
		}
		[] => Err("empty command")
	}
}

logged! : Context, U64, List(Str), Path, List(U8), U64 => Try(Examples.Ran, Str)
logged! = |context, number, argv, cwd, input, timeout| {
	setup = context.setup
	ran = run!(context, argv, cwd, input, timeout)?
	prefix = "${number.to_str()}"
	write!(Path.join(setup.directory, "${prefix}-command.json"), Json.to_str({ argv, cwd: native(context, cwd), cache: native(context, setup.cache), stdin: Str.from_utf8_lossy(input), environment: setup.environment_text, timeout_ms: timeout, status: ran.status, signal: ran.signal, error: ran.error, code: ran.code, timed_out: ran.timed_out, limited: ran.limited }))?
	Path.write_bytes!(Path.join(setup.directory, "${prefix}-stdout.log"), ran.stdout).map_err(|_| "cannot preserve stdout")?
	Path.write_bytes!(Path.join(setup.directory, "${prefix}-stderr.log"), ran.stderr).map_err(|_| "cannot preserve stderr")?
	Stdout.line!("\n${Compatibility.console(Json.to_str(argv))} (${ran.status}, code ${ran.code.to_str()}, signal ${ran.signal.to_str()}: ${Compatibility.console(ran.error)})\n${Compatibility.console(Str.from_utf8_lossy(ran.stdout))}${Compatibility.console(Str.from_utf8_lossy(ran.stderr))}").map_err(|_| "cannot display diagnostics")?
	if ran.status == "io-error" {
		return Err("command ${prefix} could not complete: ${ran.error}; inspect command logs")
	}
	Ok(ran)
}

examples! : Context, Examples.Options => Try(Examples.Outcome, Str)
examples! = |context, options| {
	setup = options.setup
	# Each replacement is passed only to the applications that declare its
	# source: the compiler refuses a replacement nothing in the graph uses.
	replacements = match options.source {
		Direct => []
		Served(bundles) =>
			match context.server {
				Server(active) => bundles.map(|entry| { from: entry.url, to: Loopback.url(active, Path.filename(entry.bundle).map_ok(Path.display) ?? "") })
				NoServer => []
			}
	}
	var $result = { tested: 0, failed: 0, skipped: 0, diagnostic_commands: 0, number: options.first_number - 1, interrupted: None, updated: { ..options.suite, apps: [] }, failures: [] }
	for example in options.suite.apps {
		source = read!(Path.join(options.root, example.path))?
		if !Compatibility.app_source(source, options.dependencies) {
			return Err("${example.path} must directly reference the declared package dependency and must not pin its compiler")
		}
		declared = (AppHeader.fields(source) ?? []).map(|field| field.source)
		replace = replacements.keep_if(|entry| declared.contains(entry.from)).join_map(|entry| ["--replace-dep", entry.from, entry.to])
		target = example.target ?? "native"
		executable = Path.join(setup.directory, "example-${($result.number + 1).to_str()}${if (target == "wasm32") ".wasm" else if (context.windows) ".exe" else ""}")
		native_executable = native(context, executable)
		native_root = native(context, options.root)
		build_target = if (target == "native") [] else ["--target=${target}"]
		# Fuzz instrumentation requires LLVM; the development backend cannot link
		# a runnable libFuzzer target. Ordinary examples keep their existing mode.
		optimization = if ((example.build_args ?? []).contains("--fuzz")) "speed" else "dev"
		var $built = Bool.True
		for argv in [[options.compiler, "check", example.path, "--no-cache"].concat(replace), [options.compiler, "build", example.path, "--no-cache", "--opt=${optimization}", "--output=${native_executable}"].concat(build_target).concat(example.build_args ?? []).concat(replace)] {
			$result = { ..$result, number: $result.number + 1 }
			ran = logged!(context, $result.number, argv, options.root, [], 300_000)?
			if ran.timed_out or ran.limited {
				return Ok({ ..$result, interrupted: if (ran.timed_out) Timeout($result.number) else OutputLimit($result.number) })
			}
			$result = { ..$result, diagnostic_commands: $result.diagnostic_commands + 1 }
			if ran.status != "exited" or ran.code != 0 {
				$built = Bool.False
			}
		}
		if !$built {
			$result = { ..$result, failed: $result.failed + 1, failures: $result.failures.append("${example.path}: did not check and build; see command ${$result.number.to_str()}") }
		}
		var $cases = []
		for case in example.cases {
			match case.skip {
				Ok(skip) => {
					$result = { ..$result, skipped: $result.skipped + 1 }
					$cases = $cases.append(case)
					Stdout.line!("SKIP ${Compatibility.console(case.name)}: ${Compatibility.console(skip.reason)} (${Compatibility.console(skip.issue)})").map_err(|_| "cannot report skip")?
				}
				Err(Missing) if $built => {
					$result = { ..$result, number: $result.number + 1 }
					runtime = match example.run {
						Ok(argv) if !argv.is_empty() => argv.map(|arg| arg.replace_each("{executable}", native_executable).replace_each("{suite}", native_root))
						_ => [native_executable]
					}
					# A case runs where a reader would run the example, in its own
					# directory, so an example reads sibling data files by relative path.
					ran = logged!(context, $result.number, runtime.concat(case.args), Path.join(options.root, directory_of(example.path)), Str.to_utf8(case.stdin), options.case_timeout_ms)?
					if ran.timed_out or ran.limited {
						return Ok({ ..$result, interrupted: if (ran.timed_out) Timeout($result.number) else OutputLimit($result.number) })
					}
					match options.mode {
						Update => {
							$result = { ..$result, tested: $result.tested + 1 }
							$cases = $cases.append({ ..case, stdout: Str.from_utf8_lossy(ran.stdout), stderr: if ((case.stderr_match ?? "exact") == "ignore") "" else Str.from_utf8_lossy(ran.stderr), exit_code: if (ran.status == "exited") ran.code else case.exit_code })
						}
						Compare => {
							passed = ran.status == "exited" and ran.code == case.exit_code and ran.stdout == Str.to_utf8(case.stdout) and Compatibility.stderr_matches(case, ran.stderr)
							$result = { ..$result, tested: $result.tested + 1, failed: $result.failed + if (passed) 0 else 1 }
							$cases = $cases.append(case)
							if !passed {
								write!(Path.join(setup.directory, "${$result.number.to_str()}-expected.json"), Json.to_str(case))?
								$result = { ..$result, failures: $result.failures.append("${example.path} [${case.name}]: ${difference(case, ran)}; see command ${$result.number.to_str()}") }
							}
						}
					}
				}
				Err(Missing) => {
					$cases = $cases.append(case)
				}
			}
		}
		$result = { ..$result, updated: { ..$result.updated, apps: $result.updated.apps.append({ ..example, cases: $cases }) } }
	}
	Ok($result)
}

# The directory an application lives in, relative to the suite root.
directory_of = |path|
	match Str.split_last(path, "/") {
		Ok({ before, .. }) => before
		Err(_) => "."
	}

expect directory_of("examples/colors.roc") == "examples" and directory_of("examples/greet/main.roc") == "examples/greet"

# The first thing that differs between a case and what actually happened.
difference : Compatibility.Case, Examples.Ran -> Str
difference = |case, ran|
	if ran.status != "exited" {
		"the example ${ran.status}"
	} else if ran.code != case.exit_code {
		"expected exit code ${case.exit_code.to_str()}, got ${ran.code.to_str()}"
	} else if ran.stdout != Str.to_utf8(case.stdout) {
		"unexpected stdout\n    expected ${visible(case.stdout)}\n    actual   ${visible(Str.from_utf8_lossy(ran.stdout))}"
	} else {
		"unexpected stderr\n    expected ${visible(case.stderr)}\n    actual   ${visible(Str.from_utf8_lossy(ran.stderr))}"
	}

# Escape sequences are what examples print, so show them instead of letting the
# terminal act on them.
visible = |text| Str.replace_each(Str.inspect(text), "\u(001b)", "\\e")

expect visible("a\u(001b)[0m\n") == "\"a\\e[0m\\n\""
