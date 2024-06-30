#!/bin/bash

echo "BUILDING HOST PRE-BUILT BINARIES -- THIS IS A TEMPORARY WORKAROUND UNTIL BASIC-CLI IS FIXED"

echo "REMOVING OLD HOST"
rm platform/*.a
rm platform/*.lib

echo "BUILDING HOST"
zig build

echo "COPYING NEW HOST"
cp zig-out/lib/libmacos-aarch64.a platform/macos-arm64.a
cp zig-out/lib/libmacos-x86_64.a platform/macos-x64.a
cp zig-out/lib/liblinux-aarch64.a platform/linux-arm64.a
cp zig-out/lib/liblinux-x86_64.a platform/linux-x64.a
cp zig-out/lib/windows-aarch64.lib platform/windows-arm64.lib
cp zig-out/lib/windows-x86_64.lib platform/windows-x64.lib

echo "DONE"
