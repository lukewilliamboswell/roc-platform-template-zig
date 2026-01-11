app [Model, program] { rr: platform "../platform/main.roc" }

Model : U64  # Frame counter

program = { init!, render! }

init! : () => Try(Model, [Exit(I64), ..])
init! = || Ok(0)

render! : Model => Try(Model, [Exit(I64), ..])
render! = |frame_count| Ok(frame_count + 1)
