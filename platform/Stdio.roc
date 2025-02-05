module [
    read_line!,
    print_line!,
]

import Effect

## Write the given string to [standard output](https://en.wikipedia.org/wiki/Standard_streams#Standard_output_(stdout)),
## followed by a newline.
print_line! : Str => {}
print_line! = |str|
    Effect.stdout_line!(str)

## Read a line from [standard input](https://en.wikipedia.org/wiki/Standard_streams#Standard_input_(stdin)).
read_line! : {} => Str
read_line! = |{}|
    Effect.stdin_line!({})
