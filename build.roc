app [main] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.10.0/vNe6s9hWzoTZtFmNkvEICPErI9ptji_ySjicO6CkucY.tar.br",
}

import cli.Cmd
import cli.Task exposing [Task]

main =

    # get the current OS and ARCH
    target = getTarget!

    # the prebuilt binary `macos-arm64.a` changes based on target
    prebuiltBinaryPath = "platform/$(prebuiltBinaryName target)"

    # build the host
    Cmd.exec "zig" ["build", "-Doptimize=ReleaseSmall"]
        |> Task.mapErr! ErrBuildingHost

    # copy pre-built binary into platform
    Cmd.exec "cp" ["-f", "zig-out/lib/libhost.a", prebuiltBinaryPath]
        |> Task.mapErr! ErrCopyPrebuiltBinary


getTarget : Task RocTarget _
getTarget =

    arch =
        Cmd.new "uname"
            |> Cmd.arg "-m"
            |> Cmd.output
            |> Task.map .stdout
            |> Task.map archFromStr
            |> Task.mapErr! \err -> ErrGettingNativeArch (Inspect.toStr err)

    os =
        Cmd.new "uname"
            |> Cmd.arg "-s"
            |> Cmd.output
            |> Task.map .stdout
            |> Task.map osFromStr
            |> Task.mapErr! \err -> ErrGettingNativeOS (Inspect.toStr err)
    rocTarget { os, arch } |> Task.fromResult!

RocTarget : [
    MacosArm64,
    MacosX64,
    LinuxArm64,
    LinuxX64,
    WindowsArm64,
    WindowsX64,
]

Arch : [
    Arm64,
    X64,
    UnsupportedArch Str,
]

Os : [
    Macos,
    Linux,
    UnsupportedOS Str,
]

archFromStr : List U8 -> Arch
archFromStr = \bytes ->
    when Str.fromUtf8 bytes is
        Ok str if str == "arm64\n" -> Arm64
        Ok str if str == "x86_64\n" -> X64
        Ok str -> UnsupportedArch str
        _ -> crash "invalid utf8 from uname -m"

osFromStr : List U8 -> Os
osFromStr = \bytes ->
    when Str.fromUtf8 bytes is
        Ok str if str == "Darwin\n" -> Macos
        Ok str if str == "Linux\n" -> Linux
        Ok str -> UnsupportedOS str
        _ -> crash "invalid utf8 from uname -s"

rocTarget : { os : Os, arch : Arch } -> Result RocTarget [UnsupportedTarget Os Arch]
rocTarget = \{ os, arch } ->
    when (os, arch) is
        (Macos, Arm64) -> Ok MacosArm64
        (Macos, X64) -> Ok MacosX64
        (Linux, Arm64) -> Ok LinuxArm64
        (Linux, X64) -> Ok LinuxX64
        _ -> Err (UnsupportedTarget os arch)

prebuiltBinaryName : RocTarget -> Str
prebuiltBinaryName = \target ->
    when target is
        MacosArm64 -> "macos-arm64.a"
        MacosX64 -> "macos-x64"
        LinuxArm64 -> "linux-arm64.a"
        LinuxX64 -> "linux-x64.a"
        WindowsArm64 -> "windows-arm64.a"
        WindowsX64 -> "windows-x64"
