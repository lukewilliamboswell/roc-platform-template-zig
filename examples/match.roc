app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/0.9/8GdFEvQYS3TeAZxKvTzCLVdQiomweGtXcdZkXNDEeABq.tar.zst" }

import pf.Stdout

# Demonstrates: match expressions on booleans
# NOTE: Type annotations on helper functions cause compiler panic

main! : List(Str) => Try({}, [Exit(I32)])
main! = |_args| {
    # Pattern match on booleans using inline match
    result1 = match True {
        True => "yes"
        False => "no"
    }
    Stdout.line!("match True: ${result1}")

    result2 = match False {
        True => "yes"
        False => "no"
    }
    Stdout.line!("match False: ${result2}")

    Ok({})
}
