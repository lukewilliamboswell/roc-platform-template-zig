app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

# Demonstrates: while loops, var/$variables, pattern matching

main! : List(Str) => Try({}, [Exit(I32)])
main! = |_args| {
    var $n = 1

    while $n <= 15 {
        output = fizzbuzz($n)
        Stdout.line!(output)
        $n = $n + 1
    }

    Ok({})
}

# Pure function that returns the fizzbuzz string for a number
fizzbuzz : I64 -> Str
fizzbuzz = |n| {
    divisible_by_3 = (n % 3) == 0
    divisible_by_5 = (n % 5) == 0

    match (divisible_by_3, divisible_by_5) {
        (True, True) => "FizzBuzz"
        (True, False) => "Fizz"
        (False, True) => "Buzz"
        (False, False) => I64.to_str(n)
    }
}
