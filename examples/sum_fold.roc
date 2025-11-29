app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

# Demonstrates: fold, pure functions, lambdas
# NOTE: Some fold operations with numbers have compiler bugs

main! : List(Str) => Try({}, [Exit(I32)])
main! = |_args| {
    # Build a string using fold - concatenate list items
    joined = ["Hello", " ", "World", "!"].fold("", |acc, s| Str.concat(acc, s))
    Stdout.line!("Joined: ${joined}")

    # Use Str.join_with for joining with separator
    csv = Str.join_with(["apple", "banana", "cherry"], ", ")
    Stdout.line!("Fruits: ${csv}")

    Ok({})
}
