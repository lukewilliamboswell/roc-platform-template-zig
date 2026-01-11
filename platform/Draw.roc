## Draw module - provides drawing primitives for the Roc raylib platform

Draw := [].{
    ## Hosted effects - implemented by the host
    begin_frame! : () => {}
    end_frame! : () => {}
    clear! : Color => {}
    rectangle! : Rectangle => {}

    ## High-level draw function with callback pattern
    ## Ensures begin/end frame are properly paired
    draw! : Color, (() => {}) => {}
    draw! = |bg_color, callback| {
        Draw.begin_frame!()
        Draw.clear!(bg_color)
        callback()
        Draw.end_frame!()
    }
}

Color : [
    Black,
    Blue,
    DarkGray,
    Gray,
    Green,
    LightGray,
    Orange,
    Pink,
    Purple,
    RayWhite,
    Red,
    White,
    Yellow,
]

Rectangle : {
    x : F32,
    y : F32,
    width : F32,
    height : F32,
    color : Color,
}
