app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Color
import rr.PlatformState

Model : {
    message: Str,
}
program = { init!, render! }

init! : () => Try(Model, [Exit(I64), ..])
init! = || Ok({
    message: "Roc :heart: Raylib!",
})

render! : Model, PlatformState => Try(Model, [Exit(I64), ..])
render! = |model, state| {
    # Animate rectangle position using frame count, wrap at 800 pixels
    rect_x = (state.frame_count % 800).to_f32()

    Draw.draw!(RayWhite, || {
        Draw.text!({ pos: { x: 10, y: 10 }, text: model.message, size: 30, color: Color.DarkGray })
        Draw.rectangle!({ x: rect_x, y: 200, width: 100, height: 80, color: Color.Red })
        Draw.circle!({ center: { x: 500, y: 400 }, radius: 50, color: Color.Green })
        Draw.line!({ start: { x: 100, y: 500 }, end: { x: 600, y: 550 }, color: Color.Blue })
    })

    Ok(model)
}
