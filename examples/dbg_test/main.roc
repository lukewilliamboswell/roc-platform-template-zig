app [main!] { roc: "nightly-2026-10-24-f6c6cfb", pf: platform "../../platform/main.roc" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str)])
main! = |_args| {
    dbg "test message"
    Stdout.line!("stdout works")?
    Ok({})
}
