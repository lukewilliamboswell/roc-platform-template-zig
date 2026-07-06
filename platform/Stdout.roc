import Host

## Utilities for writing to [standard output](https://en.wikipedia.org/wiki/Standard_streams#Standard_output_(stdout)).
Stdout := [].{
    ## Write the given string to standard output, followed by a newline.
    ##
    ## Returns `Err(StdoutErr(message))` if the host cannot write to stdout.
    line! : Str => Try({}, [StdoutErr(Str), ..])
    line! = |message|
        match Host.stdout_line!(message) {
            Ok({}) => Ok({})
            Err(StdoutErr(err)) => Err(StdoutErr(err))
        }
}
