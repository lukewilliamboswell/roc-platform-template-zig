app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

main! = |args| {
    count = List.len(args)
    Stdout.line!("Hello World! Got ${count.to_str()} args")
    0 # exit code
}
