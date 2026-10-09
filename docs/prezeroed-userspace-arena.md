# Pre-zeroed userspace append arena

`tools/appendfat_arena.c` is a userspace experiment for the stock-phone case
where the removable-storage path rejects `FALLOC_FL_KEEP_SIZE`.

It does not replace kernel appendfat and it does not emulate the keep-size
system call. Instead it pays the allocation cost once by writing zeros through a
fixed-size arena file, then keeps the logical end separately in a durable
`.used` pointer.

Files for an arena named `cache.arena` are:

```text
cache.arena       fixed-size, fully zero-written data capacity
cache.arena.used  decimal logical byte count plus newline
cache.arena.lock  stable advisory-lock inode
```

## Build

A Linux host build requires `ICK` pointing at the qualified native compiler:

```sh
"$ICK" -fno-link-libatomic -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
    -Ilib lib/appendfat_arena.c tools/appendfat_arena.c -o appendfat_arena
```

For the Android/Termux ARMv7 consumer, build off-device through the
`arena-cli` target in `android/Makefile`, supplying `ABI=armeabi-v7a`,
`NDK`, `ICK_STAGE` and `AICI_ROOT`. The target produces
`build/android-armeabi-v7a/appendfat_arena`. The default API floor is 26.
The exact compiler and source-stage requirements are in
[division-migration.md](division-migration.md).

The source uses `_FILE_OFFSET_BITS=64`.

## Create

```sh
./appendfat_arena create cache.arena 8589934592
```

Creation uses ordinary writes, not `ftruncate()` or `fallocate()`, to write
zeros through the requested capacity. After the data file is synced, the
initial logical pointer is written as `0`.

All three paths must be new. Creation refuses to replace an existing arena,
pointer, or lock.

The visible data-file size is the full capacity from the beginning. Consumers
must therefore use the logical `.used` pointer or the `dump` command rather
than treating the data file's ordinary EOF as the logical end.

## Append

Append a regular file:

```sh
./appendfat_arena append cache.arena fragment.bin
```

Append a stream:

```sh
producer | ./appendfat_arena append cache.arena -
```

The append path:

1. takes an exclusive advisory lock on the stable `.lock` inode;
2. validates that `.used` is between zero and the arena's fixed size;
3. writes beginning at the old logical end without extending the arena file;
4. syncs the arena data;
5. writes the new logical end to a new temporary pointer file;
6. syncs that file;
7. renames it over `.used`; and
8. syncs the containing directory.

The logical pointer is not advanced until all input has been read and the arena
data has been synced.

For a regular source file whose size exceeds the remaining capacity, the command
rejects it before writing data.

For stdin or another stream whose total size is unknown, overflow can be
detected only after some bytes have already overwritten previously unused arena
capacity. In that case the command fails and leaves `.used` unchanged. Those
bytes are therefore uncommitted and may be overwritten by a later append.

This is deliberate transactional behavior at the logical-data boundary. It is
not a claim about arbitrary filesystem crash points.

## Read

```sh
./appendfat_arena status cache.arena
./appendfat_arena dump cache.arena > logical-data.bin
```

`status` reports fixed capacity, committed used bytes, and free capacity.
`dump` writes only the committed prefix to stdout.

For example, a large extracted Takeout member can be streamed into a pre-zeroed
arena:

```sh
unzip -p takeout.zip 'path/to/member' |
    ./appendfat_arena append member.arena -
```

The arena file itself still has trailing zero capacity and is **not** a
byte-for-byte ordinary extracted file. Use `dump` when an ordinary logical
file is needed.

## Why this helps on the current phone

The 2026-09-18 stock-phone probe shows that the Android/Termux removable-storage
path rejects `FALLOC_FL_KEEP_SIZE`. A one-time explicit zero write uses only
ordinary file writes, so it provides a separate experiment:

- creation grows and allocates the file once;
- later logical appends overwrite offsets already inside that fixed file;
- later appends do not extend the visible data-file size;
- the small `.used` metadata file carries the changing logical end.

On FAT-like allocation this is intended to avoid repeatedly growing the large
data file's cluster chain after initial creation. The physical-phone experiment
still has to measure actual behavior on the target storage path.

## Evidence boundary

A zero-written fixed-size file is not `FALLOC_FL_KEEP_SIZE` and is not the
future appendfat allocation policy.

This tool does not establish:

- physical NAND contiguity;
- SD-controller flash-translation behavior;
- crash correctness at every FAT/exFAT metadata update point;
- durability stronger than the mounted filesystem provides for `fsync` and
  rename;
- compatibility with ordinary programs that ignore `.used`;
- automatic arena refill or growth.

The first physical receipt should record before/after file size, allocated-block
information where Android exposes it, logical `used`, and repeated appends.
