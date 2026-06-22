app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/0.9/8GdFEvQYS3TeAZxKvTzCLVdQiomweGtXcdZkXNDEeABq.tar.zst" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32)])
main! = |_args| {
    Stdout.line!("This example exits with a non-zero exit code")
    Err(Exit(23))
}
