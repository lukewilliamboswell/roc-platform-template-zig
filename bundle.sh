#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Collect all .roc files
roc_files=(platform/*.roc)

# Collect all host libraries from targets directories
lib_files=()
for lib in platform/targets/*/*.a platform/targets/*/*.lib; do
    if [[ -f "$lib" ]]; then
        lib_files+=("$lib")
    fi
done

# Also include native libhost.a if it exists
if [[ -f "platform/libhost.a" ]]; then
    lib_files+=("platform/libhost.a")
fi
if [[ -f "platform/host.lib" ]]; then
    lib_files+=("platform/host.lib")
fi

echo "Bundling ${#roc_files[@]} .roc files and ${#lib_files[@]} library files..."

roc bundle "${roc_files[@]}" "${lib_files[@]}" "$@"
