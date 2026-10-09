# `appendfat_mv`

`tools/appendfat_mv.c` is a deliberately small `mv`-style program for moving a regular file onto a filesystem that supports Linux `FALLOC_FL_KEEP_SIZE`. It is deliberately safer than ordinary `mv` around existing paths: the default is no-clobber, and replacement requires an explicit `--replace`.

For a same-filesystem move it calls `rename()` and does not rewrite the file. For a cross-filesystem move it:

1. creates a temporary file beside the final destination;
2. calls `fallocate(FALLOC_FL_KEEP_SIZE, 0, source_size)` before copying data;
3. verifies that the reservation did not increase logical file size;
4. copies exactly the snapshotted source length through the already allocated destination;
5. checks that the open source did not change size or modification time during the copy;
6. `fsync()`s the destination;
7. installs the temporary file with `RENAME_NOREPLACE` by default, so a destination that already exists — including one created during the copy — is not overwritten;
8. syncs the destination directory after publication;
9. atomically renames the source pathname into a private same-directory quarantine name;
10. verifies that the quarantined inode is the exact inode that was copied;
11. removes only that verified quarantined inode; and
12. syncs the source directory after removal.

The quarantine step closes the final pathname race between verifying the source
and deleting it. If another process replaces the source pathname before the
quarantine rename, the replacement is detected by inode identity and is never
unlinked by the mover. The mover attempts to restore it to the original path;
if a second concurrent change prevents that restoration, the mover reports the
quarantine pathname and fails. If a replacement appears after the original
inode has already been quarantined, the replacement remains at the source
pathname while the verified original is removed.

If keep-size fallocate is unsupported or returns `ENOSPC`, the move fails before data copy and leaves the source untouched. This is intentional: silently falling back to ordinary incremental allocation would defeat the purpose of the tool.

## Android ARMv7 / Thumb-2 build

Build off-device with the `mv` target in `android/Makefile`, supplying
`ABI=armeabi-v7a`, `ANDROID_API=24`, `NDK`, `ICK_STAGE` and `AICI_ROOT`.
It compiles through the pinned ICK frontend and preserves the ARMv7/Thumb-2
PIE profile. The output is `build/android-armeabi-v7a/appendfat_mv`.
See [division-migration.md](division-migration.md) for exact source pins.

The source defines `_FILE_OFFSET_BITS=64`, so the allocation and copy length are not limited to 2 GiB by the 32-bit userspace ABI. The `fallocate()` libc wrapper is used rather than issuing the ARM syscall directly, leaving bionic to handle the ARM EABI argument convention for the 64-bit offset and length.

Example, moving from internal Termux storage to the SD card:

```sh
./appendfat_mv \
    ~/takeout/archive.zip \
    ~/SD.card/archive.zip
```

An existing destination directory is also accepted:

```sh
./appendfat_mv ~/takeout/archive.zip ~/SD.card/
```

On the current MIRO A1 target, `~/SD.card` is a verified symlink to the whole removable-card root `/storage/4A21-0000`. `~/storage/external-1` is **not** the card root on this phone; it resolves to `/storage/4A21-0000/Android/data/com.termux/files`, which is Termux's app-private directory on the card.

Destination symlinks are deliberately not followed. A symlink supplied as the
destination is treated as an existing path and is refused by default, including
when the argument has trailing slashes. With `--replace`, replacement applies
to the symlink path itself rather than to its target.

`--force-copy` bypasses the same-filesystem rename fast path. It exists mainly for testing the reservation/copy path:

```sh
./appendfat_mv --force-copy source destination
```

Existing destinations are refused by default, including on the rename fast path and after a cross-filesystem copy. Replacement is opt-in:

```sh
./appendfat_mv --replace source destination
```

The no-clobber installation uses `renameat2(..., RENAME_NOREPLACE)`, so it remains safe if another process creates the destination after copying has already started.

## Current physical-phone result

The stock removable-storage path on the target phone does not currently satisfy
the reservation precondition: the 2026-09-18 physical probe returned
`EOPNOTSUPP` for `FALLOC_FL_KEEP_SIZE` through the Termux/Android FUSE view.
That is an expected fail-closed case for this utility, not appendfat evidence.

See [the retained phone probe](phone-keep-size-probe-2026-09-18.md). The same
probe must be repeated against an actual physical appendfat mount before this
tool is considered usable for the target SD-card path.

## Evidence boundary

`FALLOC_FL_KEEP_SIZE` reserves filesystem allocation beyond logical EOF. On FAT this can allocate the file's FAT cluster chain before the data copy, so later writes can consume already linked clusters rather than extending the chain one cluster at a time.

It does **not** specify physical NAND placement inside the SD card, and it does not prove that the allocated FAT clusters are contiguous. The SD controller's flash-translation layer remains outside this interface.

On Android, an SD-card path exposed through `/dev/fuse` must also pass keep-size fallocate through successfully. If the existing `fallocate --keep-size` probe succeeds on that path, `appendfat_mv` exercises the same kernel interface; otherwise this program will fail closed and report the error.

Cross-filesystem mode currently supports regular files only. It is not a complete replacement for GNU `mv`: directory trees, symlinks, xattrs, ACLs, ownership, and interactive overwrite policy are intentionally outside this first tool.

## Safety test boundary before touching an SD card

Treat removable media as if it contains unique data unless proven otherwise.

The repository separates the generic physical checks from the phone card-root wrapper:

1. `tests/physical-sd-readonly-preflight.sh SD_ROOT`
   - resolves and reports the target path;
   - records capacity, filesystem identity, mount evidence, and top-level entry count;
   - performs no writes, renames, or deletes.

2. `tests/physical-appendfat-mv-scratch.sh APPENDFAT_MV_BINARY SD_ROOT`
   - refuses to run unless `APPENDFAT_MV_PHYSICAL_SCRATCH=YES` is set;
   - creates one new private scratch directory below the supplied SD root;
   - tests no-clobber only on files it created in that directory;
   - uses a disposable source created in internal temporary storage for the reservation-before-copy path;
   - never invokes `--replace`;
   - never uses recursive deletion;
   - removes only individually named test files after verifying its ownership marker;
   - leaves the scratch directory in place rather than broadening cleanup if anything unexpected appears.

3. `tests/physical-phone-appendfat-mv-acceptance.sh APPENDFAT_MV_BINARY SD_ROOT`
   - requires the same explicit scratch-write arm;
   - rejects nested `/storage/.../...` paths such as Termux's `Android/data` directory;
   - requires `SD_ROOT` to resolve to the actual `/storage/<volume-id>` filesystem mountpoint;
   - runs the read-only preflight before the armed scratch test;
   - keeps ANSI color on the terminal while writing a plain-text receipt.

On the currently observed Android/FUSE removable-storage path, the expected reservation-before-copy result remains a safe failure with `Operation not supported (EOPNOTSUPP)`: the disposable source must remain byte-for-byte intact and no final destination may appear.

## Host safety and fault coverage

`tests/appendfat-mv.sh` exercises the qualified ICK compiler in CI and covers:

- strict compilation;
- argument errors and `--` handling;
- same-filesystem inode-preserving rename;
- same-file no-op;
- default no-clobber and explicit `--replace`;
- copy sizes at zero, one byte, and immediately below/at/above the 256 KiB buffer boundary;
- destination-directory basename behavior;
- mode and modification-time preservation;
- refusal of symlink and directory sources on the copy path;
- missing destination parents;
- no-clobber on the forced reservation/copy path;
- `Operation not supported (EOPNOTSUPP)` during reservation;
- `No space left on device (ENOSPC)` during reservation;
- one interrupted reservation followed by retry;
- destination `fsync` failure;
- final-install failure;
- source-unlink failure, which must leave both complete copies;
- a destination that appears during the copy, which must not be overwritten;
- source growth during the copy, which must prevent publication and deletion;
- a same-size in-place rewrite with the original mtime restored, which must still be detected through ctime;
- source-path replacement immediately before quarantine, which must be restored rather than deleted;
- source-path replacement after quarantine but before unlink, which must survive untouched;
- temporary-file cleanup after every pre-publication failure;
- source-quarantine cleanup after successful moves.

The fault cases are injected into the process rather than induced by damaging a filesystem.
