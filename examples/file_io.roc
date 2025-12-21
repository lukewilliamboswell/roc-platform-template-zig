app [main!] { pf: platform "../platform/main.roc" }

import pf.File
import pf.Stdout

main! : List(Str) => Try({}, [Exit(I32)])
main! = |_args| {
    Stdout.line!("Writing file")
    File.write_utf8!("test", "file contents")
    Stdout.line!("Reading file")
    text = File.read_utf8!("test")
    Stdout.line!("Printing file contents")
    Stdout.line!(text)
    Stdout.line!("Deleting file")
    File.delete!("test")
    Ok({})
}
