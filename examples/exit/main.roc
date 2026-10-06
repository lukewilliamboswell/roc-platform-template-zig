app [main!] { roc: "nightly-2026-10-04-130536d", pf: platform "../../platform/main.roc" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str)])
main! = |args| {
	if args.len() > 1 {
		Stdout.line!("This example exits successfully")?
		Ok({})
	} else {
		Stdout.line!("This example exits with a non-zero exit code")?
		Err(Exit(23))
	}
}
