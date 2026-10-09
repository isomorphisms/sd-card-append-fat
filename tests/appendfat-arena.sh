#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

"${ICK:?Set ICK to the qualified native compiler}" ${ICK_FLAGS:--fno-link-libatomic} \
    -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
    -I"$root/lib" \
    "$root/lib/appendfat_arena.c" \
    "$root/tools/appendfat_arena.c" \
    -o "$work/appendfat_arena"

"${ICK:?Set ICK to the qualified native compiler}" ${ICK_FLAGS:--fno-link-libatomic} \
    -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
    -I"$root/lib" \
    "$root/lib/appendfat_arena.c" \
    "$root/tests/appendfat-arena-library.c" \
    -o "$work/appendfat_arena_library"

"$work/appendfat_arena_library" "$work/library.arena"

arena="$work/cache.arena"

"$work/appendfat_arena" create "$arena" 1048576
test "$(stat -c '%s' "$arena")" = 1048576
test "$(cat "$arena.used")" = 0
test -f "$arena.lock"
"$work/appendfat_arena" status "$arena" |
    grep -qx 'capacity_bytes=1048576 used_bytes=0 free_bytes=1048576'

printf 'alpha\n' > "$work/first"
"$work/appendfat_arena" append "$arena" "$work/first"
test "$(stat -c '%s' "$arena")" = 1048576
test "$(cat "$arena.used")" = 6
"$work/appendfat_arena" dump "$arena" > "$work/dump-1"
cmp "$work/first" "$work/dump-1"

printf 'beta\n' |
    "$work/appendfat_arena" append "$arena" -
test "$(stat -c '%s' "$arena")" = 1048576
test "$(cat "$arena.used")" = 11
printf 'alpha\nbeta\n' > "$work/expected"
"$work/appendfat_arena" dump "$arena" > "$work/dump-2"
cmp "$work/expected" "$work/dump-2"

dd if=/dev/zero of="$work/too-large" bs=1048576 count=1 status=none
if "$work/appendfat_arena" append "$arena" "$work/too-large" 2>/dev/null; then
    printf '%s\n' 'oversize regular-file append unexpectedly succeeded' >&2
    exit 1
fi
test "$(cat "$arena.used")" = 11
"$work/appendfat_arena" dump "$arena" > "$work/dump-after-file-overflow"
cmp "$work/expected" "$work/dump-after-file-overflow"

python3 - "$work/stdin-overflow" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'x' * (1048576 - 11 + 1))
PY
if "$work/appendfat_arena" append "$arena" - \
    < "$work/stdin-overflow" 2>/dev/null
then
    printf '%s\n' 'oversize stdin append unexpectedly succeeded' >&2
    exit 1
fi
test "$(cat "$arena.used")" = 11
"$work/appendfat_arena" dump "$arena" > "$work/dump-after-stdin-overflow"
cmp "$work/expected" "$work/dump-after-stdin-overflow"
test "$(stat -c '%s' "$arena")" = 1048576

if "$work/appendfat_arena" create "$arena" 1024 2>/dev/null; then
    printf '%s\n' 'duplicate create unexpectedly succeeded' >&2
    exit 1
fi
test "$(stat -c '%s' "$arena")" = 1048576
test "$(cat "$arena.used")" = 11

printf '1048577\n' > "$arena.used"
if "$work/appendfat_arena" status "$arena" >/dev/null 2>&1; then
    printf '%s\n' 'invalid used pointer unexpectedly accepted' >&2
    exit 1
fi

printf '%s\n' 'appendfat_arena host tests: PASS'
