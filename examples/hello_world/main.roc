app [main!] { roc: "nightly-2026-10-09-258ab27", pf: platform "../../platform/main.roc" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str)])
main! = |_args| {
    Stdout.line!("Hello, World!")?
    Ok({})
}
