# appendFAT C67 arena sandbox

This APK compiles the repository's existing `tools/appendfat_arena.c` into a
small Android NativeActivity for the MIRO C67 (`arm64-v8a`).

It requests no Android permissions. The test uses only
`ANativeActivity.internalDataPath`, creates a 4 MiB pre-zeroed
`cache.arena`, appends a deterministic payload, commits the `.used` pointer,
reopens the arena, verifies the payload bytes, and verifies untouched capacity
is still zero.

A green screen and PASS toast mean the userspace arena test passed. A red
screen and FAIL toast mean it failed. Details are also written under the
`appendfat-arena` logcat tag.

This is deliberately not a kernel-module installer. It does not use root or
Shizuku, mount or unmount filesystems, format media, open raw block devices, or
write shared/external storage. It therefore does not establish physical
SD-card write reduction or the `fs/appendfat` kernel reservation behavior.
