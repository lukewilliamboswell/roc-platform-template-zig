app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Color

Model : U64  # Frame counter

program = { init!, render! }

init! : () => Try(Model, [Exit(I64), ..])
init! = || Ok(0)

render! : Model => Try(Model, [Exit(I64), ..])
render! = |frame_count| {
    Draw.draw!(RayWhite, || {
        Draw.text!({ pos: { x: 10, y: 10 }, text: "Hello from Roc!", size: 30, color: Color.DarkGray })
        Draw.rectangle!({ x: 100, y: 100, width: 200, height: 100, color: Color.Red })
        Draw.circle!({ center: { x: 500, y: 150 }, radius: 50, color: Color.Green })
        Draw.line!({ start: { x: 100, y: 300 }, end: { x: 600, y: 400 }, color: Color.Blue })
    })
    Ok(frame_count + 1)
}
