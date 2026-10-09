#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' "usage: $0 /path/to/linux" >&2
    exit 2
fi

repo=$(git rev-parse --show-toplevel)
linux_tree=$1

. "$repo/tests/qemu-common.sh"

appendfat_require_commands busybox "${ICK:?Set ICK to the qualified native compiler}" cpio fsck.fat mkfs.fat qemu-system-x86_64 timeout truncate
appendfat_prepare_linux "$repo" "$linux_tree" builtin

work=$(mktemp -d "${TMPDIR:-/tmp}/appendfat-fat-matrix.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

fat12=$work/fat12.img
fat16=$work/fat16.img
fat32=$work/fat32.img
root=$work/initramfs
initramfs=$work/initramfs.cpio.gz
qemu_log=$work/qemu.log
helper=$work/fallocate-keep-size

truncate -s 8M "$fat12"
truncate -s 64M "$fat16"
truncate -s 128M "$fat32"
mkfs.fat -F 12 -n AFAT12 "$fat12"
mkfs.fat -F 16 -n AFAT16 "$fat16"
mkfs.fat -F 32 -n AFAT32 "$fat32"

"${ICK:?Set ICK to the qualified native compiler}" ${ICK_FLAGS:--fno-link-libatomic} -O2 -static -Wall -Wextra -Werror \
    "$repo/tests/fallocate-keep-size.c" -o "$helper" -Wl,--start-group -lc -lgcc_eh -Wl,--end-group

mkdir -p "$root/bin" "$root/proc" "$root/sys" "$root/dev" "$root/mnt"
cp "$(command -v busybox)" "$root/bin/busybox"
cp "$helper" "$root/bin/fallocate-keep-size"
for applet in sh mount umount mkdir cat sync poweroff grep
do
    ln -s busybox "$root/bin/$applet"
done
cp "$repo/tests/qemu-fat-matrix-init" "$root/init"
chmod +x "$root/init"

appendfat_make_initramfs "$root" "$initramfs"

set +e
timeout 150s qemu-system-x86_64 \
    -machine accel=tcg \
    -m 512M \
    -smp 2 \
    -nographic \
    -no-reboot \
    -kernel "$linux_tree/arch/x86/boot/bzImage" \
    -initrd "$initramfs" \
    -append 'console=ttyS0 rdinit=/init panic=-1' \
    -drive "file=$fat12,format=raw,if=virtio" \
    -drive "file=$fat16,format=raw,if=virtio" \
    -drive "file=$fat32,format=raw,if=virtio" \
    > "$qemu_log" 2>&1
qemu_status=$?
set -e

cat "$qemu_log"
grep -F APPENDFAT_QEMU_FAT_MATRIX_PASS "$qemu_log"

if [ "$qemu_status" -ne 0 ] && [ "$qemu_status" -ne 124 ]; then
    printf '%s\n' "qemu exited unexpectedly: $qemu_status" >&2
    exit "$qemu_status"
fi

for image in "$fat12" "$fat16" "$fat32"
do
    fsck.fat -n -v "$image"
done

printf '%s\n' 'appendfat FAT12/FAT16/FAT32 and representative mount-option matrix passed'
