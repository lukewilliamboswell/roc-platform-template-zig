app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/0.9/8GdFEvQYS3TeAZxKvTzCLVdQiomweGtXcdZkXNDEeABq.tar.zst" }

import pf.Stdout

main! = |_args| {
    Stdout.line!("Hello, World!")
    Ok({})
}
