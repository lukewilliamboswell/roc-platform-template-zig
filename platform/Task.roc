# this module will become a builtin
module [
    Task,
    ok,
    err,
    await,
    map,
    mapErr,
    onErr,
    attempt,
    forever,
    loop,
    fromResult,
    batch,
    seq,
    forEach,
    result,

    fromEffect,
    toEffect,
]

import Effect exposing [Effect]

Task ok err := Effect (Result ok err)

fromEffect : Effect (Result ok err) -> Task ok err
fromEffect = \effect -> @Task effect

toEffect : Task ok err -> Effect (Result ok err)
toEffect = \@Task effect -> effect

## Run a task that never ends. Note that this task does not return a value.
forever : Task a err -> Task * err
forever = \task ->
    looper = \{} ->
        task
        |> toEffect
        |> Effect.map
            \res ->
                when res is
                    Ok _ -> Step {}
                    Err e -> Done (Err e)

    Effect.loop {} looper
    |> fromEffect

## Run a task repeatedly, until it fails with `err` or completes with `done`.
## Check out [this example](https://www.roc-lang.org/examples/TaskLoop/README.html).
loop : state, (state -> Task [Step state, Done done] err) -> Task done err
loop = \state, step ->
    looper = \current ->
        step current
        |> toEffect
        |> Effect.map
            \res ->
                when res is
                    Ok (Step newState) -> Step newState
                    Ok (Done newResult) -> Done (Ok newResult)
                    Err e -> Done (Err e)

    Effect.loop state looper
    |> fromEffect

## Create a task that always succeeds with the value provided.
##
## ```
## # Always succeeds with "Louis"
## getName : Task.Task Str *
## getName = Task.ok "Louis"
## ```
##
ok : a -> Task a *
ok = \a -> @Task (Effect.always (Ok a))

## Create a task that always fails with the error provided.
##
## ```
## # Always fails with the tag `CustomError Str`
## customError : Str -> Task.Task {} [CustomError Str]
## customError = \err -> Task.err (CustomError err)
## ```
##
err : a -> Task * a
err = \a -> @Task (Effect.always (Err a))

## Transform a given Task with a function that handles the success or error case
## and returns another task based on that. This is useful for chaining tasks
## together or performing error handling and recovery.
##
## Consider a the following task;
##
## `canFail : Task {} [Failure, AnotherFail, YetAnotherFail]`
##
## We can use [attempt] to handle the failure cases using the following;
##
## ```
## result <- canFail |> Task.attempt
## when result is
##     Ok Success -> Stdout.line "Success!"
##     Err Failure -> Stdout.line "Oops, failed!"
##     Err AnotherFail -> Stdout.line "Ooooops, another failure!"
##     Err YetAnotherFail -> Stdout.line "Really big oooooops, yet again!"
## ```
##
## Here we know that the `canFail` task may fail, and so we use
## `Task.attempt` to convert the task to a `Result` and then use pattern
## matching to handle the success and possible failure cases.
##
attempt : Task a b, (Result a b -> Task c d) -> Task c d
attempt = \task, transform ->
    effect = Effect.after
        (toEffect task)
        \res ->
            when res is
                Ok a -> transform (Ok a) |> toEffect
                Err b -> transform (Err b) |> toEffect

    fromEffect effect

## Take the success value from a given [Task] and use that to generate a new [Task].
##
## For example we can use this to run tasks in sequence like follows;
##
## ```
## # Prints "Hello World!\n" to standard output.
## {} <- Stdout.write "Hello "|> Task.await
## {} <- Stdout.write "World!\n"|> Task.await
##
## Task.ok {}
## ```
await : Task a b, (a -> Task c b) -> Task c b
await = \task, transform ->
    effect = Effect.after
        (toEffect task)
        \res ->
            when res is
                Ok a -> transform a |> toEffect
                Err b -> err b |> toEffect

    fromEffect effect

## Take the error value from a given [Task] and use that to generate a new [Task].
##
## ```
## # Prints "Something went wrong!" to standard error if `canFail` fails.
## canFail
## |> Task.onErr \_ -> Stderr.line "Something went wrong!"
## ```
onErr : Task a b, (b -> Task a c) -> Task a c
onErr = \task, transform ->
    effect = Effect.after
        (toEffect task)
        \res ->
            when res is
                Ok a -> ok a |> toEffect
                Err b -> transform b |> toEffect

    fromEffect effect

## Transform the success value of a given [Task] with a given function.
##
## ```
## # Succeeds with a value of "Bonjour Louis!"
## Task.ok "Louis"
## |> Task.map (\name -> "Bonjour $(name)!")
## ```
map : Task a c, (a -> b) -> Task b c
map = \task, transform ->
    effect = Effect.after
        (toEffect task)
        \res ->
            when res is
                Ok a -> ok (transform a) |> toEffect
                Err b -> err b |> toEffect

    fromEffect effect

## Transform the error value of a given [Task] with a given function.
##
## ```
## # Ignore the fail value, and map it to the tag `CustomError`
## canFail
## |> Task.mapErr \_ -> CustomError
## ```
mapErr : Task c a, (a -> b) -> Task c b
mapErr = \task, transform ->
    effect = Effect.after
        (toEffect task)
        \res ->
            when res is
                Ok c -> ok c |> toEffect
                Err a -> err (transform a) |> toEffect

    fromEffect effect

## Use a Result among other Tasks by converting it into a [Task].
fromResult : Result a b -> Task a b
fromResult = \res ->
    when res is
        Ok a -> ok a
        Err b -> err b

## Apply a task to another task applicatively. This can be used with
## [ok] to build a [Task] that returns a record.
##
## The following example returns a Record with two fields, `apples` and
## `oranges`, each of which is a `List Str`. If it fails it returns the tag
## `NoFruitAvailable`.
##
## ```
## getFruitBasket : Task { apples : List Str, oranges : List Str } [NoFruitAvailable]
## getFruitBasket = Task.ok {
##     apples: <- getFruit Apples |> Task.batch,
##     oranges: <- getFruit Oranges |> Task.batch,
## }
## ```
batch : Task a c -> (Task (a -> b) c -> Task b c)
batch = \current -> \next ->
        f <- next |> await

        map current f

## Apply each task in a list sequentially, and return a list of the resulting values.
## Each task will be awaited before beginning the next task.
##
## ```
## fetchAuthorTasks : List (Task Author [DbError])
##
## getAuthors : Task (List Author) [DbError]
## getAuthors = Task.seq fetchAuthorTasks
## ```
##
seq : List (Task ok err) -> Task (List ok) err
seq = \tasks ->
    List.walk tasks (ok []) \state, task ->
        value <- task |> await

        state |> map \values -> List.append values value

## Apply a task repeatedly for each item in a list
##
## ```
## authors : List Author
## saveAuthor : Author -> Task {} [DbError]
##
## saveAuthors : Task (List Author) [DbError]
## saveAuthors = Task.forEach authors saveAuthor
## ```
##
forEach : List a, (a -> Task {} b) -> Task {} b
forEach = \items, fn ->
    List.walk items (ok {}) \state, item ->
        state |> await \_ -> fn item

## Transform a task that can either succeed with `ok`, or fail with `err`, into
## a task that succeeds with `Result ok err`.
##
## This is useful when chaining tasks using the `!` suffix. For example:
##
## ```
## # Path.roc
## checkFile : Str -> Task [Good, Bad] [IOError]
##
## # main.roc
## when checkFile "/usr/local/bin/roc" |> Task.result! is
##     Ok Good -> "..."
##     Ok Bad -> "..."
##     Err IOError -> "..."
## ```
##
result : Task ok err -> Task (Result ok err) *
result = \task ->
    effect =
        Effect.after
            (toEffect task)
            \res -> res |> ok |> toEffect

    fromEffect effect
