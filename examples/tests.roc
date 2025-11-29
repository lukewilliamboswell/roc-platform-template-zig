app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

# Demonstrates: expect keyword for testing
# Run with: roc test examples/tests.roc
# NOTE: Type annotations on helper functions cause compiler panic

main! : List(Str) => Try({}, [Exit(I32)])
main! = |_args| {
    Stdout.line!("Run 'roc test --verbose examples/tests.roc' to execute the tests")
    Ok({})
}

# --- Simple expects for demonstration ---

# Basic arithmetic
expect 1 + 1 == 2
expect 10 - 3 == 7
expect 4 * 5 == 20

# Boolean logic
expect True == True
expect False == False
expect True != False

# String operations
expect Str.concat("Hello", " World") == "Hello World"
expect Str.is_empty("")
expect Str.is_empty("hi") == False
