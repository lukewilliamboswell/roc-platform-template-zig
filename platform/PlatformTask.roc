# this module will be replaced when effect interpreters are implemented
hosted PlatformTask
    exposes [
        stdoutLine,
    ]
    imports []

# tasks that are provided by the host
stdoutLine : Str -> Task {} Str
