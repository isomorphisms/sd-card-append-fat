#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' "usage: $0 /path/to/linux" >&2
    exit 2
fi

repo=$(git rev-parse --show-toplevel)
linux_tree=$1
work=$(mktemp -d "${TMPDIR:-/tmp}/appendfat-reserve-ahead-mutations.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

mutant_repo=$work/repo
mutant_file=$mutant_repo/fs/appendfat/inode.c
mutant_log=$work/no-reserve-ahead.log

# Run the existing QEMU acceptance gate against a disposable source copy whose
# ordinary write path requests only the required cluster.  This is the
# behavioral opposite of reserve-ahead, not a compile-only source check.
cp -a "$repo" "$mutant_repo"
test "$(grep -c 'APPENDFAT_APPEND_AHEAD_CLUSTERS);' "$mutant_file")" -eq 1
sed -i \
    -e 's/err = appendfat_add_clusters(inode,/err = appendfat_add_cluster(inode); \/\* reserve-ahead mutant disabled \*\//' \
    -e '/APPENDFAT_APPEND_AHEAD_CLUSTERS);/d' \
    "$mutant_file"
cmp -s "$repo/fs/appendfat/inode.c" "$mutant_file" && {
    printf '%s\n' 'reserve-ahead mutant did not alter inode.c' >&2
    exit 1
}

if (
    cd "$mutant_repo"
    sh tests/qemu-reserve-ahead.sh "$linux_tree"
) >"$mutant_log" 2>&1; then
    cat "$mutant_log" >&2
    printf '%s\n' 'reserve-ahead acceptance gate survived disabled reserve-ahead' >&2
    exit 1
fi

grep -F 'reserve_ahead_initial state mismatch' "$mutant_log" >/dev/null || {
    cat "$mutant_log" >&2
    printf '%s\n' 'reserve-ahead mutant failed for an unexpected reason' >&2
    exit 1
}

printf '%s\n' 'appendfat reserve-ahead mutation test: PASS'
