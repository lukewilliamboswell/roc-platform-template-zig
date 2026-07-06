app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst" }

import pf.Stdin
import pf.Stdout

# Demonstrates: Stdin.line!, interactive I/O, effectful functions

main! : List(Str) => Try({}, [Exit(I32), StdinErr(Str), StdoutErr(Str), ..])
main! = |_args| {
    Stdout.line!("Enter something and I'll echo it back:")?

    input = Stdin.line!({})?
    Stdout.line!("You entered: ${input}")?

    Ok({})
}
