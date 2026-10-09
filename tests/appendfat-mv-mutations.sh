#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

source_file="$root/tools/appendfat_mv.c"

fail()
{
    printf 'FAIL  %s\n' "$*" >&2
    exit 1
}

pass()
{
    printf 'PASS  %s\n' "$*"
}

compile_mutant()
{
    mutant=$1
    "${ICK:?Set ICK to the qualified native compiler}" ${ICK_FLAGS:--fno-link-libatomic} \
        -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
        "$mutant" \
        -o "$work/mutant-binary"
}

require_killed()
{
    name=$1
    mutant=$2

    cmp -s "$source_file" "$mutant" &&
        fail "mutation $name did not change the source"

    compile_mutant "$mutant" ||
        fail "mutation $name did not compile; this is not a useful behavioral mutant"

    if APPENDFAT_MV_SOURCE_FILE="$mutant" \
       sh "$root/tests/appendfat-mv.sh" \
       >"$work/$name.stdout" 2>"$work/$name.stderr"; then
        printf '%s\n' "--- $name stdout ---" >&2
        cat "$work/$name.stdout" >&2
        printf '%s\n' "--- $name stderr ---" >&2
        cat "$work/$name.stderr" >&2
        fail "test suite survived dangerous mutation: $name"
    fi

    pass "suite kills mutant: $name"
}

mutant="$work/no-clobber.c"
cp "$source_file" "$mutant"
sed -i '0,/if (allow_replace)/s//if (allow_replace || !allow_replace)/' "$mutant"
require_killed no-clobber "$mutant"

mutant="$work/no-reservation.c"
cp "$source_file" "$mutant"
sed -i '0,/if (length == 0)/s//if (length >= 0)/' "$mutant"
require_killed no-reservation "$mutant"

mutant="$work/no-destination-fsync.c"
cp "$source_file" "$mutant"
sed -i '0,/if (fsync(destination_fd) != 0)/s//if (false \&\& fsync(destination_fd) != 0)/' "$mutant"
require_killed no-destination-fsync "$mutant"

mutant="$work/no-source-unlink.c"
cp "$source_file" "$mutant"
sed -i '0,/if (unlink(quarantine) != 0)/s//if (false)/' "$mutant"
require_killed no-source-unlink "$mutant"

mutant="$work/leak-temporary.c"
cp "$source_file" "$mutant"
sed -i '0,/if (!destination_installed)/s//if (destination_installed \&\& !destination_installed)/' "$mutant"
require_killed leak-temporary "$mutant"

mutant="$work/ignore-source-change.c"
cp "$source_file" "$mutant"
sed -i \
    -e 's/final_source_status.st_size != source_status.st_size ||/false ||/' \
    -e 's/final_source_status.st_mtim.tv_sec != source_status.st_mtim.tv_sec ||/false ||/' \
    -e 's/final_source_status.st_mtim.tv_nsec != source_status.st_mtim.tv_nsec ||/false ||/' \
    -e 's/final_source_status.st_ctim.tv_sec != source_status.st_ctim.tv_sec ||/false ||/' \
    -e 's/final_source_status.st_ctim.tv_nsec != source_status.st_ctim.tv_nsec)/false)/' \
    "$mutant"
require_killed ignore-source-change "$mutant"

printf 'appendfat_mv mutation tests: PASS\n'
