#!/bin/sh
set -eu
if [ -z "$ICK" ]; then
    echo "ICK must identify the qualified compiler; no fallback compiler" >&2
    exit 2
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d /tmp/appendfat-fskit-XXXXXXXX)
trap 'rm -f "$scratch/append.arena" "$scratch/append.arena.used" "$scratch/append.arena.lock" "$scratch/bridge-test"; rmdir "$scratch"' EXIT HUP INT TERM
"$ICK" -fno-link-libatomic -std=c11 -O2 -Wall -Wextra -Werror -I"$root/lib" \
    "$root/lib/appendfat_arena.c" \
    "$root/macos/fskit/AppendFATFSKitExtension/AppendFATBridge.c" \
    "$root/tests/fskit-bridge.c" -o "$scratch/bridge-test"
"$scratch/bridge-test" "$scratch/append.arena"
