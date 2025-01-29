app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.19.0/Hj-J_zxz7V9YurCSTFcFdu6cQJie4guzsPMUi5kBYUk.tar.br",
}

import cli.Cmd
import cli.Env

main! = |_args|

    { os, arch } = Env.platform!({})

    roc = Env.var!("ROC") ?? "roc"

    build_stub!(roc, os)?

    # Note we use ReleaseFast to disable the stack probe which causes issues on Intel Macs
    #
    # You may wish to remove this if you want debug symbols...
    #
    # We see the following error in CI
    # ```
    #    Undefined symbols for architecture x86_64:
    #    "___zig_probe_stack", referenced from:
    #        _debug.panicExtra__anon_3134 in libhost.a.o)
    #        _debug.panicExtra__anon_3136 in libhost.a.o)
    #        _debug.panicExtra__anon_3730 in libhost.a.o)
    #        _debug.panicExtra__anon_4078 in libhost.a.o)
    #        _debug.ModuleDebugInfo__struct_4612.loadOFile in libhost.a.o)
    #        _dwarf.DwarfInfo.getLineNumberInfo in libhost.a.o)
    #        _debug.printLineFromFileAnyOs__anon_7202 in libhost.a.o)
    #        ...
    #    ld: symbol(s) not found for architecture x86_64
    # ```
    Cmd.exec!("zig", ["build", "-Doptimize=ReleaseFast"]) ? ErrBuildingZigHost

    Cmd.exec!("cp", ["-f", "zig-out/lib/libhost.a", "./platform/libhost.a"]) ? ErrCopyPrebuiltLegacyHost

    build_surgical_host!(roc, os, arch)

build_stub! = |roc, os|
    # zig will link these shared libraries to build a dynhost executable
    # which is used to build the surgical host
    when os is
        LINUX ->
            Cmd.exec!(roc, ["build", "--lib", "--output", "./platform/libapp.so", "./platform/stub.roc"]) ? ErrBuildingStubDylibLinux

        MACOS ->
            Cmd.exec!(roc, ["build", "--lib", "--output", "./platform/libapp.dylib", "./platform/stub.roc"]) ? ErrBuildingStubDylibMacos

        WINDOWS ->
            Cmd.exec!(roc, ["build", "--lib", "--output", "./platform/app.lib", "./platform/stub.roc"]) ? ErrBuildingStubDylibWindows

        OTHER(os_str) ->
            crash("OS ${os_str} not supported, build.roc probably needs updating")

    Ok({})

build_surgical_host! = |roc, os, arch|
    if os == LINUX and arch == X64 then
        # prebuilt surgical hosts are only supported/used on linux-x64 for now
        Cmd.exec!(roc, ["preprocess-host", "zig-out/bin/dynhost", "./platform/main.roc", "./platform/libapp.so"]) ? ErrBuildingPrebuiltSurgicalHostLinuxX64

        Ok({})
    else
        Ok({})
