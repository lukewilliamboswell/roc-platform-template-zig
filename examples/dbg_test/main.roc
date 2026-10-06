app [main!] { roc: "nightly-2026-10-04-130536d", pf: platform "../../platform/main.roc" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str)])
main! = |_args| {
    dbg "test message"
    Stdout.line!("stdout works")?
    Ok({})
}
