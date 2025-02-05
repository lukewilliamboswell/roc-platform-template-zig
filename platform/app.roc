app [init!, run!] { pf: platform "../platform/main.roc" }

init! : {} => Str
init! = |{}|
    "Hello"

run! : Str => Result {} _
run! = |greeting|
    if greeting == "Hello" then
        Ok({})
    else
        Err(99)
