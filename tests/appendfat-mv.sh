#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

binary="$work/appendfat_mv"
faults="$work/appendfat-mv-faults.so"
source_under_test=${APPENDFAT_MV_SOURCE_FILE:-"$root/tools/appendfat_mv.c"}

fail()
{
    printf 'FAIL  %s\n' "$*" >&2
    exit 1
}

pass()
{
    printf 'PASS  %s\n' "$*"
}

expect_fail()
{
    if "$@"; then
        fail "command unexpectedly succeeded: $*"
    fi
}

expect_status()
{
    expected=$1
    shift
    set +e
    "$@"
    status=$?
    set -e
    test "$status" -eq "$expected" ||
        fail "expected status $expected, got $status: $*"
}

assert_no_temporary()
{
    destination=$1
    directory=$(dirname "$destination")
    base=$(basename "$destination")

    if find "$directory" -maxdepth 1 -name "$base.appendfat_mv.tmp.*" -print -quit |
       grep -q .; then
        fail "temporary destination leaked beside $destination"
    fi
}

assert_no_source_quarantine()
{
    source=$1
    directory=$(dirname "$source")
    base=$(basename "$source")

    if find "$directory" -maxdepth 1 -name "$base.appendfat_mv.source.*" -print -quit |
       grep -q .; then
        fail "source quarantine leaked beside $source"
    fi
}

build()
{
    "${ICK:?Set ICK to the qualified native compiler}" ${ICK_FLAGS:--fno-link-libatomic} \
        -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
        "$source_under_test" \
        -o "$binary"

    "${ICK:?Set ICK to the qualified native compiler}" ${ICK_FLAGS:--fno-link-libatomic} \
        -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared \
        "$root/tests/appendfat-mv-faults.c" \
        -ldl \
        -o "$faults"
}

build
pass "strict build"

expect_status 2 "$binary"
expect_status 2 "$binary" --not-an-option source destination
pass "argument validation"

mkdir "$work/rename"
printf 'rename path\n' > "$work/rename/source"
cp "$work/rename/source" "$work/rename/expected"
before=$(stat -c '%d:%i' "$work/rename/source")
"$binary" "$work/rename/source" "$work/rename/destination"
after=$(stat -c '%d:%i' "$work/rename/destination")
test "$before" = "$after" || fail "same-filesystem rename changed inode"
cmp "$work/rename/expected" "$work/rename/destination"
test ! -e "$work/rename/source"
pass "same-filesystem rename fast path"

printf 'same file\n' > "$work/same-file"
"$binary" "$work/same-file" "$work/same-file"
printf 'same file\n' > "$work/same-expected"
cmp "$work/same-expected" "$work/same-file"
pass "source and destination are the same file"

mkdir "$work/no-clobber"
printf 'new source\n' > "$work/no-clobber/source"
printf 'old destination\n' > "$work/no-clobber/destination"
cp "$work/no-clobber/source" "$work/no-clobber/source-expected"
cp "$work/no-clobber/destination" "$work/no-clobber/destination-expected"
expect_fail "$binary" "$work/no-clobber/source" "$work/no-clobber/destination"
cmp "$work/no-clobber/source-expected" "$work/no-clobber/source"
cmp "$work/no-clobber/destination-expected" "$work/no-clobber/destination"
pass "same-filesystem move refuses to clobber an existing destination"

printf 'symlink source\n' > "$work/symlink-destination-source"
ln -s "$work/symlink-destination-source" "$work/symlink-destination"
expect_fail "$binary" "$work/symlink-destination-source" "$work/symlink-destination"
test -f "$work/symlink-destination-source"
test -L "$work/symlink-destination"
pass "destination symlink to source is refused instead of treated as a same-file no-op"

mkdir "$work/symlink-directory-target"
ln -s "$work/symlink-directory-target" "$work/symlink-directory-destination"
printf 'do not follow directory symlink\n' > "$work/symlink-directory-source"
expect_fail "$binary" "$work/symlink-directory-source" "$work/symlink-directory-destination"
test -f "$work/symlink-directory-source"
test -L "$work/symlink-directory-destination"
test ! -e "$work/symlink-directory-target/symlink-directory-source"
pass "destination symlink to a directory is not followed"

mkdir "$work/symlink-slash-target"
ln -s "$work/symlink-slash-target" "$work/symlink-slash-destination"
printf 'trailing slash must not follow symlink\n' > "$work/symlink-slash-source"
expect_fail "$binary" "$work/symlink-slash-source" "$work/symlink-slash-destination/"
test -f "$work/symlink-slash-source"
test -L "$work/symlink-slash-destination"
test ! -e "$work/symlink-slash-target/symlink-slash-source"
pass "trailing slash does not make a destination symlink behave like its target directory"

printf 'explicitly replace trailing-slash symlink\n' > "$work/symlink-slash-replace-source"
"$binary" --replace "$work/symlink-slash-replace-source" "$work/symlink-slash-destination/"
test ! -L "$work/symlink-slash-destination"
test -f "$work/symlink-slash-destination"
printf 'explicitly replace trailing-slash symlink\n' > "$work/symlink-slash-replace-expected"
cmp "$work/symlink-slash-replace-expected" "$work/symlink-slash-destination"
test -d "$work/symlink-slash-target"
pass "explicit --replace replaces the symlink path itself even with a trailing slash"

printf 'replacement source\n' > "$work/no-clobber/replace-source"
printf 'replacement old\n' > "$work/no-clobber/replace-destination"
"$binary" --replace "$work/no-clobber/replace-source" "$work/no-clobber/replace-destination"
printf 'replacement source\n' > "$work/no-clobber/replace-expected"
cmp "$work/no-clobber/replace-expected" "$work/no-clobber/replace-destination"
test ! -e "$work/no-clobber/replace-source"
pass "explicit --replace permits same-filesystem replacement"

mkdir "$work/dash"
(
    cd "$work/dash"
    printf 'dash name\n' > ./-source
    "$binary" -- ./-source ./-destination
    printf 'dash name\n' > expected
    cmp expected ./-destination
    test ! -e ./-source
)
pass "-- permits path names beginning with a dash"

mkdir "$work/sizes"
for size in 0 1 262143 262144 262145 1048593
do
    source="$work/sizes/source-$size"
    destination="$work/sizes/destination-$size"
    expected="$work/sizes/expected-$size"

    if test "$size" -eq 0; then
        : > "$source"
    else
        dd if=/dev/urandom of="$source" bs=1 count="$size" status=none
    fi
    cp "$source" "$expected"

    "$binary" --force-copy "$source" "$destination"
    cmp "$expected" "$destination"
    test ! -e "$source"
    assert_no_temporary "$destination"
    assert_no_source_quarantine "$source"
done
pass "reserved copy sizes around the 256 KiB buffer boundary"

mkdir "$work/directory-target"
printf 'directory destination\n' > "$work/directory-source"
"$binary" --force-copy "$work/directory-source" "$work/directory-target"
printf 'directory destination\n' > "$work/directory-expected"
cmp "$work/directory-expected" "$work/directory-target/directory-source"
test ! -e "$work/directory-source"
pass "existing destination directory uses source basename"

printf 'metadata\n' > "$work/metadata-source"
chmod 0640 "$work/metadata-source"
touch -d '@946684800' "$work/metadata-source"
"$binary" --force-copy "$work/metadata-source" "$work/metadata-destination"
test "$(stat -c '%a' "$work/metadata-destination")" = 640 ||
    fail "destination mode was not preserved"
test "$(stat -c '%Y' "$work/metadata-destination")" = 946684800 ||
    fail "destination modification time was not preserved"
pass "mode and modification time preservation"

printf 'important target\n' > "$work/symlink-target"
ln -s "$work/symlink-target" "$work/symlink-source"
expect_fail "$binary" --force-copy "$work/symlink-source" "$work/symlink-source-copy-destination"
printf 'important target\n' > "$work/symlink-expected"
cmp "$work/symlink-expected" "$work/symlink-target"
test -L "$work/symlink-source"
test ! -e "$work/symlink-source-copy-destination"
pass "cross-filesystem-style path refuses a symbolic-link source"

mkdir "$work/directory-source"
expect_fail "$binary" --force-copy "$work/directory-source" "$work/directory-copy"
test -d "$work/directory-source"
test ! -e "$work/directory-copy"
pass "cross-filesystem-style path refuses a directory source"

printf 'missing parent\n' > "$work/missing-parent-source"
expect_fail "$binary" --force-copy "$work/missing-parent-source" "$work/no-such-parent/destination"
test -f "$work/missing-parent-source"
pass "missing destination parent leaves source untouched"

printf 'new protected source\n' > "$work/protected-source"
printf 'old protected destination\n' > "$work/protected-destination"
cp "$work/protected-source" "$work/protected-source-expected"
cp "$work/protected-destination" "$work/protected-destination-expected"
expect_fail "$binary" --force-copy "$work/protected-source" "$work/protected-destination"
cmp "$work/protected-source-expected" "$work/protected-source"
cmp "$work/protected-destination-expected" "$work/protected-destination"
assert_no_temporary "$work/protected-destination"
pass "forced copy still refuses to clobber an existing destination"

printf 'explicit replacement\n' > "$work/force-replace-source"
printf 'old explicit replacement\n' > "$work/force-replace-destination"
"$binary" --force-copy --replace \
    "$work/force-replace-source" "$work/force-replace-destination"
printf 'explicit replacement\n' > "$work/force-replace-expected"
cmp "$work/force-replace-expected" "$work/force-replace-destination"
test ! -e "$work/force-replace-source"
pass "forced copy replaces only with explicit --replace"

fault_case()
{
    mode=$1
    errno_name=$2
    source="$work/fault-$mode-source"
    destination="$work/fault-$mode-destination"
    marker="$work/fault-$mode-fired"

    printf 'fault case %s\n' "$mode" > "$source"
    cp "$source" "$source.expected"

    expect_fail env \
        APPENDFAT_MV_FAULT="$mode" \
        APPENDFAT_MV_SOURCE="$source" \
        APPENDFAT_MV_MARKER="$marker" \
        LD_PRELOAD="$faults" \
        "$binary" --force-copy "$source" "$destination"

    test -e "$marker" || fail "$errno_name injector did not fire"
    cmp "$source.expected" "$source"
    test ! -e "$destination"
    assert_no_temporary "$destination"
    pass "$errno_name leaves the source untouched and cleans the temporary file"
}

fault_case fallocate_eopnotsupp "Operation not supported (EOPNOTSUPP)"
fault_case fallocate_enospc "No space left on device (ENOSPC)"
fault_case fsync_eio "destination sync failure"
fault_case install_eio "destination install failure"

printf 'interrupted allocation\n' > "$work/eintr-source"
cp "$work/eintr-source" "$work/eintr-expected"
env \
    APPENDFAT_MV_FAULT=fallocate_eintr_once \
    APPENDFAT_MV_MARKER="$work/eintr-fired" \
    LD_PRELOAD="$faults" \
    "$binary" --force-copy "$work/eintr-source" "$work/eintr-destination"
test -e "$work/eintr-fired" || fail "Interrupted system call (EINTR) injector did not fire"
cmp "$work/eintr-expected" "$work/eintr-destination"
test ! -e "$work/eintr-source"
pass "Interrupted system call (EINTR) during reservation is retried"

printf 'unlink failure\n' > "$work/unlink-source"
cp "$work/unlink-source" "$work/unlink-expected"
expect_fail env \
    APPENDFAT_MV_FAULT=source_unlink_eio \
    APPENDFAT_MV_SOURCE="$work/unlink-source" \
    APPENDFAT_MV_MARKER="$work/unlink-fired" \
    LD_PRELOAD="$faults" \
    "$binary" --force-copy "$work/unlink-source" "$work/unlink-destination"
test -e "$work/unlink-fired" || fail "source unlink injector did not fire"
cmp "$work/unlink-expected" "$work/unlink-source"
cmp "$work/unlink-expected" "$work/unlink-destination"
pass "source unlink failure leaves both complete copies"

printf 'destination parent sync failure\n' > "$work/destination-parent-source"
cp "$work/destination-parent-source" "$work/destination-parent-expected"
expect_fail env \
    APPENDFAT_MV_FAULT=destination_parent_fsync_eio \
    APPENDFAT_MV_SOURCE="$work/destination-parent-source" \
    APPENDFAT_MV_MARKER="$work/destination-parent-fired" \
    LD_PRELOAD="$faults" \
    "$binary" --force-copy \
    "$work/destination-parent-source" "$work/destination-parent-destination"
test -e "$work/destination-parent-fired" ||
    fail "destination parent sync injector did not fire"
cmp "$work/destination-parent-expected" "$work/destination-parent-source"
cmp "$work/destination-parent-expected" "$work/destination-parent-destination"
pass "destination parent sync failure leaves both complete copies"

printf 'source parent sync failure\n' > "$work/source-parent-source"
cp "$work/source-parent-source" "$work/source-parent-expected"
expect_fail env \
    APPENDFAT_MV_FAULT=source_parent_fsync_eio \
    APPENDFAT_MV_SOURCE="$work/source-parent-source" \
    APPENDFAT_MV_MARKER="$work/source-parent-fired" \
    LD_PRELOAD="$faults" \
    "$binary" --force-copy \
    "$work/source-parent-source" "$work/source-parent-destination"
test -e "$work/source-parent-fired" ||
    fail "source parent sync injector did not fire"
test ! -e "$work/source-parent-source"
cmp "$work/source-parent-expected" "$work/source-parent-destination"
pass "source parent sync failure reports uncertainty after source removal"

dd if=/dev/urandom of="$work/race-source" bs=1M count=2 status=none
cp "$work/race-source" "$work/race-expected"
race_marker="$work/race-marker"
env \
    APPENDFAT_MV_FAULT=pause_before_install \
    APPENDFAT_MV_MARKER="$race_marker" \
    LD_PRELOAD="$faults" \
    "$binary" --force-copy "$work/race-source" "$work/race-destination" \
    >"$work/race.stdout" 2>"$work/race.stderr" &
race_pid=$!

i=0
while test ! -e "$race_marker" && test "$i" -lt 200
do
    sleep 0.01
    i=$((i + 1))
done
test -e "$race_marker" || fail "race test did not reach install boundary"
printf 'appeared during move\n' > "$work/race-destination"
if wait "$race_pid"; then
    fail "race-safe no-clobber test unexpectedly succeeded"
fi
cmp "$work/race-expected" "$work/race-source"
printf 'appeared during move\n' > "$work/race-destination-expected"
cmp "$work/race-destination-expected" "$work/race-destination"
assert_no_temporary "$work/race-destination"
pass "destination created during copy is not overwritten"

dd if=/dev/urandom of="$work/quarantine-race-source" bs=1M count=2 status=none
cp "$work/quarantine-race-source" "$work/quarantine-race-expected"
quarantine_race_marker="$work/quarantine-race-marker"
env \
    APPENDFAT_MV_FAULT=pause_before_source_quarantine \
    APPENDFAT_MV_MARKER="$quarantine_race_marker" \
    APPENDFAT_MV_SOURCE="$work/quarantine-race-source" \
    LD_PRELOAD="$faults" \
    "$binary" --force-copy \
    "$work/quarantine-race-source" "$work/quarantine-race-destination" \
    >"$work/quarantine-race.stdout" 2>"$work/quarantine-race.stderr" &
quarantine_race_pid=$!

i=0
while test ! -e "$quarantine_race_marker" && test "$i" -lt 200
do
    sleep 0.01
    i=$((i + 1))
done
test -e "$quarantine_race_marker" || fail "source-quarantine race did not reach rename boundary"

mv "$work/quarantine-race-source" "$work/quarantine-race-original-moved"
printf 'replacement before quarantine rename\n' > "$work/quarantine-race-source"

if wait "$quarantine_race_pid"; then
    fail "source replacement before quarantine rename unexpectedly succeeded"
fi

cmp "$work/quarantine-race-expected" "$work/quarantine-race-destination"
printf 'replacement before quarantine rename\n' > "$work/quarantine-race-replacement-expected"
cmp "$work/quarantine-race-replacement-expected" "$work/quarantine-race-source"
cmp "$work/quarantine-race-expected" "$work/quarantine-race-original-moved"
assert_no_temporary "$work/quarantine-race-destination"
assert_no_source_quarantine "$work/quarantine-race-source"
pass "source replacement before quarantine is restored rather than deleted"

dd if=/dev/urandom of="$work/remove-race-source" bs=1M count=2 status=none
cp "$work/remove-race-source" "$work/remove-race-expected"
remove_race_marker="$work/remove-race-marker"
env \
    APPENDFAT_MV_FAULT=pause_before_source_unlink \
    APPENDFAT_MV_MARKER="$remove_race_marker" \
    APPENDFAT_MV_SOURCE="$work/remove-race-source" \
    LD_PRELOAD="$faults" \
    "$binary" --force-copy \
    "$work/remove-race-source" "$work/remove-race-destination" \
    >"$work/remove-race.stdout" 2>"$work/remove-race.stderr" &
remove_race_pid=$!

i=0
while test ! -e "$remove_race_marker" && test "$i" -lt 200
do
    sleep 0.01
    i=$((i + 1))
done
test -e "$remove_race_marker" || fail "source-removal race did not reach unlink boundary"

if test -e "$work/remove-race-source"; then
    mv "$work/remove-race-source" "$work/remove-race-old-source"
fi
printf 'replacement created during source removal\n' > "$work/remove-race-source"

if ! wait "$remove_race_pid"; then
    cat "$work/remove-race.stderr" >&2
    fail "source-removal race unexpectedly failed"
fi

cmp "$work/remove-race-expected" "$work/remove-race-destination"
printf 'replacement created during source removal\n' > "$work/remove-race-replacement-expected"
cmp "$work/remove-race-replacement-expected" "$work/remove-race-source"
test ! -e "$work/remove-race-old-source" ||
    fail "original source was renamed aside instead of being removed by the mover"
assert_no_temporary "$work/remove-race-destination"
assert_no_source_quarantine "$work/remove-race-source"
pass "replacement created at the source path during removal is not deleted"

dd if=/dev/urandom of="$work/mutate-source" bs=1M count=2 status=none
mutate_marker="$work/mutate-marker"
env \
    APPENDFAT_MV_FAULT=pause_source_read \
    APPENDFAT_MV_MARKER="$mutate_marker" \
    APPENDFAT_MV_SOURCE="$work/mutate-source" \
    LD_PRELOAD="$faults" \
    "$binary" --force-copy "$work/mutate-source" "$work/mutate-destination" \
    >"$work/mutate.stdout" 2>"$work/mutate.stderr" &
mutate_pid=$!

i=0
while test ! -e "$mutate_marker" && test "$i" -lt 200
do
    sleep 0.01
    i=$((i + 1))
done
test -e "$mutate_marker" || fail "mutation test did not reach source read"
printf 'source changed\n' >> "$work/mutate-source"
if wait "$mutate_pid"; then
    fail "source mutation test unexpectedly succeeded"
fi
test -f "$work/mutate-source"
test ! -e "$work/mutate-destination"
assert_no_temporary "$work/mutate-destination"
pass "source growth during copy prevents publication and deletion"

dd if=/dev/urandom of="$work/mutate-same-size-source" bs=1M count=2 status=none
cp -p "$work/mutate-same-size-source" "$work/mutate-same-size-time-reference"
mutate_same_marker="$work/mutate-same-size-marker"
env \
    APPENDFAT_MV_FAULT=pause_source_read \
    APPENDFAT_MV_MARKER="$mutate_same_marker" \
    APPENDFAT_MV_SOURCE="$work/mutate-same-size-source" \
    LD_PRELOAD="$faults" \
    "$binary" --force-copy \
    "$work/mutate-same-size-source" "$work/mutate-same-size-destination" \
    >"$work/mutate-same-size.stdout" 2>"$work/mutate-same-size.stderr" &
mutate_same_pid=$!

i=0
while test ! -e "$mutate_same_marker" && test "$i" -lt 200
do
    sleep 0.01
    i=$((i + 1))
done
test -e "$mutate_same_marker" || fail "same-size mutation test did not reach source read"

printf 'Z' | dd of="$work/mutate-same-size-source" bs=1 seek=1048576 conv=notrunc status=none
touch -r "$work/mutate-same-size-time-reference" "$work/mutate-same-size-source"

if wait "$mutate_same_pid"; then
    fail "same-size source mutation with restored mtime unexpectedly succeeded"
fi
test -f "$work/mutate-same-size-source"
test ! -e "$work/mutate-same-size-destination"
assert_no_temporary "$work/mutate-same-size-destination"
assert_no_source_quarantine "$work/mutate-same-size-source"
pass "ctime detects same-size source rewrite even after mtime is restored"

printf 'appendfat_mv host and fault-injection tests: PASS\n'
