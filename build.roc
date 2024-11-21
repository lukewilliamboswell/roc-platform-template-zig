app [main] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.16.0/O00IPk-Krg_diNS2dVWlI0ZQP794Vctxzv0ha96mK0E.tar.br",
}

import cli.Cmd

main =

    Cmd.exec "roc" ["build", "--lib", "--output", "platform/libapp.dylib", "platform/stub.roc"]
    |> Task.mapErr! ErrBuildingStubDylib

    Cmd.exec "zig" ["build", "-Doptimize=ReleaseFast"]
    |> Task.mapErr! ErrBuildingZigHost

    Cmd.exec "cp" ["-f", "zig-out/lib/libhost.a", "platform/libhost.a"]
    |> Task.mapErr! ErrCopyPrebuiltLegacyHost

    Cmd.exec "roc" ["preprocess-host", "zig-out/bin/dynhost", "platform/main.roc", "platform/libapp.dylib"]
    |> Task.mapErr! ErrBuildingPrebuiltSurgicalHost
