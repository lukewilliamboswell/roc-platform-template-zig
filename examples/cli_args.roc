app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/0.9/8GdFEvQYS3TeAZxKvTzCLVdQiomweGtXcdZkXNDEeABq.tar.zst" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32)])
main! = |args| {
    Stdout.line!("Hello Roc!")

    args_str = Str.join_with(args, ", ")
    Stdout.line!("Args: ${args_str}")

    Ok({})
}
