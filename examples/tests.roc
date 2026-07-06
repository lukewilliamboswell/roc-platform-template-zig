app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst" }

import pf.Stdout

# Demonstrates: expect keyword for testing
# Run with: roc test examples/tests.roc
# NOTE: Type annotations on helper functions cause compiler panic

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str), ..])
main! = |_args| {
    Stdout.line!("Run 'roc test --verbose examples/tests.roc' to execute the tests")?
    Ok({})
}

# --- Simple expects for demonstration ---

## Addition works for small integers.
expect 1 + 1 == 2

## Subtraction works for small integers.
expect 10 - 3 == 7

## Multiplication works for small integers.
expect 4 * 5 == 20

## True equals itself.
expect True == True

## False equals itself.
expect False == False

## True and False are distinct values.
expect True != False

## Strings can be concatenated.
expect Str.concat("Hello", " World") == "Hello World"

## Empty strings report as empty.
expect Str.is_empty("")

## Non-empty strings do not report as empty.
expect Str.is_empty("hi") == False
