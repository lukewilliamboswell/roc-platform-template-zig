import Host

## Utilities for writing to [standard error](https://en.wikipedia.org/wiki/Standard_streams#Standard_error_(stderr)).
Stderr := [].{
    ## Write the given string to standard error, followed by a newline.
    ##
    ## Returns `Err(StderrErr(message))` if the host cannot write to stderr.
    line! : Str => Try({}, [StderrErr(Str), ..])
    line! = |message|
        match Host.stderr_line!(message) {
            Ok({}) => Ok({})
            Err(StderrErr(err)) => Err(StderrErr(err))
        }
}
