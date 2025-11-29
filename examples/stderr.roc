app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout
import pf.Stderr

# Demonstrates: Stderr output, both output streams

main! : List(Str) => Try({}, [Exit(I32)])
main! = |_args| {
    # Write to stdout
    Stdout.line!("This message goes to stdout")
    Stdout.line!("You can redirect it with: roc run example.roc > out.txt")

    # Write to stderr
    Stderr.line!("This message goes to stderr")
    Stderr.line!("You can redirect it with: roc run example.roc 2> err.txt")

    # Return success
    Ok({})
}
