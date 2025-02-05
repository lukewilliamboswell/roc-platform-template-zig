platform ""
    requires {} {
        init! : {} => Str,
        run! : Str => Result {} I32
    }
    exposes [Stdio]
    packages {}
    imports []
    provides [init_for_host!, run_for_host!]

init_for_host! : {} => Str
init_for_host! = |{}|
    init!({})

run_for_host! : Str => I32
run_for_host! = |str|
    when run!(str) is
        Ok({}) -> 0
        Err(exit_code) -> exit_code
