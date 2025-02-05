#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euo pipefail

rm -rf app.o libmain.a app

zig build-obj -O ReleaseFast host/app.zig
zig build-lib -O ReleaseFast host/main.zig
zig build-exe -fstrip app.o libmain.a

ls -hl ./app

./app

echo $?
