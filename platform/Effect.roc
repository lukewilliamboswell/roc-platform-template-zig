# this module will be replaced when effect interpreters are implemented
hosted Effect
    exposes [
        Effect,
        after,
        map,
        always,
        forever,
        loop,

        stdoutLine,
    ]
    imports []
    generates Effect with [after, map, always, forever, loop]

# effects that are provided by the host
stdoutLine : Str -> Effect (Result {} Str)
