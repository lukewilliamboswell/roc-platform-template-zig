app [main!] { pf: platform "../../platform/main.roc" }

import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str)])
main! = |args| {
    Stdout.line!("Hello Roc!")?

    # The first argument is the program itself.
    args_str = Str.join_with(args.drop_first(1), ", ")
    Stdout.line!("Args: ${args_str}")?

    Ok({})
}
