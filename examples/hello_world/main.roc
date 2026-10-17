app [main!] { roc: "nightly-2026-10-17-5f126ac", pf: platform "../../platform/main.roc" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str)])
main! = |_args| {
    Stdout.line!("Hello, World!")?
    Ok({})
}
