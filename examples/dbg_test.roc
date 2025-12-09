app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

main! = |_args| {
    dbg "test message"
    Stdout.line!("stdout works")
    Ok({})
}
