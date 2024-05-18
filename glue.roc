# plugin for generating platform glue files for this platform
app [makeGlue] {
    pf: platform "https://github.com/lukewilliamboswell/roc/releases/download/test/olBfrjtI-HycorWJMxdy7Dl2pcbbBoJy4mnSrDtRrlI.tar.br",
}

import pf.Types exposing [Types]
import pf.File exposing [File]

makeGlue : List Types -> Result (List File) Str
makeGlue = \typesByArch ->
    typesByArch
    |> List.map convertTypesToFile
    |> List.concat staticFiles
    |> Ok

staticFiles : List File
staticFiles = []

convertTypesToFile : Types -> File
convertTypesToFile = \_ ->
    { name: "todo.md", content: "TODO generate glue from the types..." }
