app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst" }

import pf.Stdin
import pf.Stdout

# Demonstrates: Reading multiline input from stdin until EOF, while loops, for loops, List.append

main! : List(Str) => Try({}, [Exit(I32), StdinErr(Str), StdoutErr(Str), ..])
main! = |_args| {
    var $lines = []
    var $continue = True

    # Read all lines from stdin until EOF (which returns empty string)
    while $continue {
        line = Stdin.line!({})?

        # Empty string indicates EOF
        if line == "" {
            $continue = False
        } else {
            $lines = List.append($lines, line)
        }
    }

    # Echo all lines back
    for line in $lines {
        Stdout.line!(line)?
    }

    Ok({})
}
