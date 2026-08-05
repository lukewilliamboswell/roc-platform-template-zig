app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str), ..])
main! = |args| {
	if args.len() > 1 {
		Stdout.line!("This example exits successfully")?
		Ok({})
	} else {
		Stdout.line!("This example exits with a non-zero exit code")?
		Err(Exit(23))
	}
}
