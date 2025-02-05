#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euo pipefail

rm -rf app.o libmain.a app

zig build-obj host/app.zig
zig build-lib host/main.zig
zig build-exe app.o libmain.a

ls -hl ./app

./app

echo $?
