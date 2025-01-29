platform ""
    requires {} { main! : {} => Result {} [Exit I32 Str]_ }
    exposes [Stdout]
    packages {}
    imports []
    provides [main_for_host!]

import Stdout

main_for_host! : I32 => I32
main_for_host! = |_|
    when main!({}) is

        Ok({}) -> 0

        Err(Exit(code, str)) ->
            if Str.is_empty(str) then
                code
            else
                Stdout.line!(str)
                code

        Err(other) ->
            Stdout.line!("Program exited early with error: ${Inspect.to_str(other)}")
            1
