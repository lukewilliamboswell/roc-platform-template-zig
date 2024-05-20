app [main] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.10.0/vNe6s9hWzoTZtFmNkvEICPErI9ptji_ySjicO6CkucY.tar.br",
}

import cli.Cmd
import cli.Task exposing [Task]

main =

    # generate glue for builtins and platform
    Cmd.exec "roc" ["glue", "glue.roc", "host/", "platform/main.roc"]
        |> Task.mapErr! ErrGeneratingGlue

    # build the host (cross-compile for supported targets)
    Cmd.exec "zig" ["build", "-Doptimize=ReleaseSmall"]
        |> Task.mapErr! ErrBuildingHost

    # copy pre-built binaries into platform
    copyPrebuiltBinary! { from: "zig-out/lib/libmacos-aarch64.a", to: "platform/macos-arm64.a" }
    copyPrebuiltBinary! { from: "zig-out/lib/libmacos-x86_64.a", to: "platform/macos-x64.a" }
    copyPrebuiltBinary! { from: "zig-out/lib/liblinux-aarch64.a", to: "platform/linux-arm64.a" }
    copyPrebuiltBinary! { from: "zig-out/lib/liblinux-x86_64.a", to: "platform/linux-x64.a" }
    copyPrebuiltBinary! { from: "zig-out/lib/windows-aarch64.lib", to: "platform/windows-arm64.lib" }
    copyPrebuiltBinary! { from: "zig-out/lib/windows-x86_64.lib", to: "platform/windows-x64.lib" }

copyPrebuiltBinary : { from : Str, to : Str } -> Task {} _
copyPrebuiltBinary = \{ from, to } ->
    Cmd.exec "cp" ["-f", from, to]
    |> Task.mapErr \err -> ErrCopyPrebuiltBinary { from, to } err
