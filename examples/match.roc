app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst" }

import pf.Stdout

# Demonstrates: match expressions on booleans

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str), ..])
main! = |args| {
    # Pattern match on booleans derived from command-line input
    no_extra_args = args.len() == 1
    has_extra_args = args.len() > 1

    result1 = match no_extra_args {
        True => "yes"
        False => "no"
    }
    Stdout.line!("match no extra args: ${result1}")?

    result2 = match has_extra_args {
        True => "yes"
        False => "no"
    }
    Stdout.line!("match extra args: ${result2}")?

    Ok({})
}
