import Host

## Utilities for reading from [standard input](https://en.wikipedia.org/wiki/Standard_streams#Standard_input_(stdin)).
Stdin := [].{
    ## Read one line from standard input.
    ##
    ## The returned string does not include the trailing newline. On EOF this returns
    ## an empty string.
    ##
    ## Returns `Err(StdinErr(message))` if the host cannot read from stdin.
    line! : {} => Try(Str, [StdinErr(Str), ..])
    line! = |{}|
        match Host.stdin_line!({}) {
            Ok(line) => Ok(line)
            Err(StdinErr(err)) => Err(StdinErr(err))
        }
}
