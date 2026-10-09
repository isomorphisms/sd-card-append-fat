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
export APPENDFAT_ALLOC_METRICS=1
appendfat_prepare_linux "$repo" "$linux_tree" builtin

work=$(mktemp -d "${TMPDIR:-/tmp}/appendfat-keep-size.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

fat_image=$work/reservation.img
enospc_image=$work/enospc.img
root=$work/initramfs
initramfs=$work/initramfs.cpio.gz
qemu_log=$work/qemu.log
helper=$work/fallocate-keep-size

truncate -s 64M "$fat_image"
truncate -s 32M "$enospc_image"
mkfs.fat -F 32 -n AFRESERVE "$fat_image"
mkfs.fat -F 16 -n AFENOSPC "$enospc_image"

"${ICK:?Set ICK to the qualified native compiler}" ${ICK_FLAGS:--fno-link-libatomic} -O2 -static -Wall -Wextra -Werror \
    "$repo/tests/fallocate-keep-size.c" \
    -o "$helper" -Wl,--start-group -lc -lgcc_eh -Wl,--end-group

mkdir -p "$root/bin" "$root/proc" "$root/sys" "$root/dev" "$root/mnt" "$root/tmp"
cp "$(command -v busybox)" "$root/bin/busybox"
for applet in sh mount umount mkdir cat sync poweroff grep dd rm
do
    ln -s busybox "$root/bin/$applet"
done
cp "$helper" "$root/bin/fallocate-keep-size"
cp "$repo/tests/qemu-keep-size-init" "$root/init"
chmod +x "$root/init" "$root/bin/fallocate-keep-size"

appendfat_make_initramfs "$root" "$initramfs"

set +e
timeout 180s qemu-system-x86_64 \
    -machine accel=tcg \
    -m 512M \
    -smp 2 \
    -nographic \
    -no-reboot \
    -kernel "$linux_tree/arch/x86/boot/bzImage" \
    -initrd "$initramfs" \
    -append 'console=ttyS0 rdinit=/init panic=-1' \
    -drive "file=$fat_image,format=raw,if=virtio" \
    -drive "file=$enospc_image,format=raw,if=virtio" \
    > "$qemu_log" 2>&1
qemu_status=$?
set -e

cat "$qemu_log"
grep -F APPENDFAT_QEMU_KEEP_SIZE_PASS "$qemu_log"

if [ "$qemu_status" -ne 0 ] && [ "$qemu_status" -ne 124 ]; then
    printf '%s\n' "qemu exited unexpectedly: $qemu_status" >&2
    exit "$qemu_status"
fi

fsck.fat -n -v "$fat_image"
fsck.fat -n -v "$enospc_image"
printf '%s\n' 'appendfat FALLOC_FL_KEEP_SIZE compatibility fixture passed'
