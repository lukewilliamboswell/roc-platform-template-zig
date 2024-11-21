platform ""
    requires {} { main! : {} => Result {} [Exit I32 Str]_ }
    exposes [Stdout]
    packages {}
    imports []
    provides [mainForHost!]

import Stdout

mainForHost! : I32 => I32
mainForHost! = \_ ->
    result = main! {}

    when result is
        Ok {} -> 0
        Err (Exit code str) ->
            if Str.isEmpty str then
                code
            else
                Stdout.line! str
                code

        Err other ->
            Stdout.line! "Program exited early with error: $(Inspect.toStr other)"
            1
