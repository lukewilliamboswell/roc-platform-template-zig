app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str), ..])
main! = |_args| {
    Stdout.line!("This example exits with a non-zero exit code")?
    Err(Exit(23))
}
