#!/bin/bash

set -e

echo "BUILDING HOST PRE-BUILT BINARIES -- THIS IS A TEMPORARY WORKAROUND UNTIL BASIC-CLI IS FIXED"

echo "REMOVING OLD HOST"
rm -f platform/*.a
rm -f platform/*.lib

unset NIX_CFLAGS_COMPILE

echo "BUILDING HOST"
zig build

echo "COPYING NEW HOST - DONT LOOK TOO CLOSELY ITS A HACK"
cp -f zig-out/lib/libhost.a platform/macos-arm64.a
cp -f zig-out/lib/libhost.a platform/macos-x64.a
cp -f zig-out/lib/libhost.a platform/linux-arm64.a
cp -f zig-out/lib/libhost.a platform/linux-x64.a

echo "generate out app.dylib or app.so file"
roc build --lib libapp.roc

echo "COPY dynhost INTO platform/"
cp -f zig-out/bin/dynhost platform/dynhost
