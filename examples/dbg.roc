app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

main! = || {

    dbg 42
    dbg "foo"

    Stdout.line!("This example shows how to use the dbg statement")
}
