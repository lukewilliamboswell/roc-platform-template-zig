app [main!] { roc: "nightly-2026-10-15-38e6c42", pf: platform "../../platform/main.roc" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str)])
main! = |_args| {
    dbg "test message"
    Stdout.line!("stdout works")?
    Ok({})
}
