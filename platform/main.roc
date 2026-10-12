platform ""
    # Applications may return their own error tags; main_for_host! reports them.
    requires {} { main! : List(Str) => Try({}, _) }
    exposes [Stdout, Stderr, Stdin]
    packages { roc: "nightly-2026-10-11-7d256b9" }
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_stderr_line": Host.stderr_line!,
        "roc_stdin_line": Host.stdin_line!,
        "roc_stdout_line": Host.stdout_line!,
    }
    targets: {
        inputs_dir: "targets/",
        x64mac: { inputs: ["libhost.a", app] },
        arm64mac: { inputs: ["libhost.a", app] },
        x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
        x64v1musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
        arm64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
        arm64v1musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
        x64win: { inputs: [
            "host.lib",
            app,
            "msvc_runtime.lib",
            "advapi32.lib",
            "api-ms-win-crt-conio-l1-1-0.lib",
            "api-ms-win-crt-convert-l1-1-0.lib",
            "api-ms-win-crt-environment-l1-1-0.lib",
            "api-ms-win-crt-filesystem-l1-1-0.lib",
            "api-ms-win-crt-heap-l1-1-0.lib",
            "api-ms-win-crt-locale-l1-1-0.lib",
            "api-ms-win-crt-math-l1-1-0.lib",
            "api-ms-win-crt-multibyte-l1-1-0.lib",
            "api-ms-win-crt-private-l1-1-0.lib",
            "api-ms-win-crt-process-l1-1-0.lib",
            "api-ms-win-crt-runtime-l1-1-0.lib",
            "api-ms-win-crt-stdio-l1-1-0.lib",
            "api-ms-win-crt-string-l1-1-0.lib",
            "api-ms-win-crt-time-l1-1-0.lib",
            "api-ms-win-crt-utility-l1-1-0.lib",
            "kernel32.lib",
            "ntdll.lib",
            "shell32.lib",
            "user32.lib",
        ] },
    }

import Stdout
import Stderr
import Stdin
import Host

main_for_host! : List(Str) => I32
main_for_host! = |args| {
    result = main!(args)
    match result {
        Ok({}) => 0
        Err(Exit(code)) => code
        Err(other) => {
            _ = Stderr.line!("ERROR: ${Str.inspect(other)}")
            -1
        }
    }
}
