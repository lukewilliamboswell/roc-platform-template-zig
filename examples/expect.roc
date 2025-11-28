app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

main! = || {
    Stdout.line!("This example shows how to write unit tests using expect, run with `roc test`")
}

expect 42 == (40+2)
expect "foo" == "fo".concat("o")
