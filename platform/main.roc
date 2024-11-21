platform ""
    requires {} { main! : {} => Result {} [Exit I32 Str]_ }
    exposes [Stdout]
    packages {}
    imports []
    provides [mainForHost!]

import Stdout

mainForHost! : I32 => Result {} I32
mainForHost! = \_ ->
    result = main! {}

    when result is
        Ok {} -> Ok {}
        Err (Exit code str) ->
            if Str.isEmpty str then
                Err code
            else
                Stdout.line! str
                Err code

        Err other ->
            Stdout.line! "Program exited early with error: $(Inspect.toStr other)"
            Err 1
