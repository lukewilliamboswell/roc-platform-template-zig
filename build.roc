app [main] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.16.0/O00IPk-Krg_diNS2dVWlI0ZQP794Vctxzv0ha96mK0E.tar.br",
}

import cli.Cmd
import cli.Env

main =

    { os } = Env.platform!

    buildStub! os

    Cmd.exec "zig" ["build"]
    |> Task.mapErr! ErrBuildingZigHost

    Cmd.exec "cp" ["-f", "zig-out/lib/libhost.a", "platform/libhost.a"]
    |> Task.mapErr! ErrCopyPrebuiltLegacyHost

    buildSurgicalHost! os

buildStub = \os ->
    # prebuilt surgical hosts are only supported on linux for now
    when os is
        LINUX ->
            Cmd.exec "roc" ["build", "--lib", "--output", "platform/libapp.so", "platform/stub.roc"]
            |> Task.mapErr ErrBuildingStubDylib
        MACOS ->
            Cmd.exec "roc" ["build", "--lib", "--output", "platform/libapp.dylib", "platform/stub.roc"]
            |> Task.mapErr ErrBuildingStubDylib
        WINDOWS ->
            Cmd.exec "roc" ["build", "--lib", "--output", "platform/app.lib", "platform/stub.roc"]
            |> Task.mapErr ErrBuildingStubDylib
        OTHER osStr ->
            crash "OS $(osStr) not supported, build.roc probably needs updating"

buildSurgicalHost = \os ->
    when os is
        LINUX ->
            # prebuilt surgical hosts are only supported/used on linux for now
            Cmd.exec "roc" ["preprocess-host", "zig-out/bin/dynhost", "platform/main.roc", "platform/libapp.dylib"]
            |> Task.mapErr! ErrBuildingPrebuiltSurgicalHost
        _ ->
            Task.ok {}
