app [Model, program] { rr: platform "../platform/main.roc" }

Model : Str

program = { init!, render! }

init! : () => Try(Model, [Exit(I64), ..])
init! = || Ok("initial model")

render! : Model => Try(Model, [Exit(I64), ..])
render! = |prev| if (prev == "initial model") Ok("rendered model") else Err(ReceivedUnexpectedModel)
