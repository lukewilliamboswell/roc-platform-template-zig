#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euo pipefail

zig build-obj host/app.zig
zig build-lib host/main.zig
zig build-exe app.o libmain.a

./app
