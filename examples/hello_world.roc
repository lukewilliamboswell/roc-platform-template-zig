app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw

Model : U64  # Frame counter

program = { init!, render! }

init! : () => Try(Model, [Exit(I64), ..])
init! = || Ok(0)

render! : Model => Try(Model, [Exit(I64), ..])
render! = |frame_count| {
    Draw.draw!(RayWhite, ||
        Draw.rectangle!({ x: 100, y: 100, width: 200, height: 150, color: Red })
    )
    Ok(frame_count + 1)
}
