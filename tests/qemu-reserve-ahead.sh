#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' "usage: $0 /path/to/linux" >&2
    exit 2
fi

repo=$(git rev-parse --show-toplevel)
linux_tree=$1

. "$repo/tests/qemu-common.sh"

appendfat_require_commands awk busybox cc cpio fsck.fat mkfs.fat mshowfat qemu-system-x86_64 timeout truncate
export APPENDFAT_RESERVATION_METRICS=1
appendfat_prepare_linux "$repo" "$linux_tree" builtin

appendfat_check_fat_chain()
{
    image=$1
    image_path=$2
    expected_clusters=$3

    mshowfat -i "$image" "$image_path" | awk -v expected="$expected_clusters" '
        {
            print
            if (NF < 2)
                exit 1
            for (field = 2; field <= NF; field++) {
                entry = $field
                if (entry !~ /^<[0-9][0-9]*(-[0-9][0-9]*)?>$/)
                    exit 1
                gsub(/[<>]/, "", entry)
                parts = split(entry, ends, "-")
                if (parts == 1)
                    clusters++
                else if (parts == 2)
                    clusters += ends[2] - ends[1] + 1
                else
                    exit 1
            }
            records++
        }
        END {
            exit records != 1 || clusters != expected
        }
    '
}

work=$(mktemp -d "${TMPDIR:-/tmp}/appendfat-reserve-ahead.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

normal_image=$work/normal.img
near_full_image=$work/near-full.img
root=$work/initramfs
initramfs=$work/initramfs.cpio.gz
qemu_log=$work/qemu.log
helper=$work/appendfat-fixture

truncate -s 64M "$normal_image"
truncate -s 16M "$near_full_image"
mkfs.fat -F 32 -s 1 -n AFAHEAD "$normal_image"
mkfs.fat -F 16 -s 1 -n AFFULL "$near_full_image"

cc -O2 -static -Wall -Wextra -Werror \
    "$repo/tests/fallocate-keep-size.c" \
    -o "$helper"

mkdir -p "$root/bin" "$root/proc" "$root/sys" "$root/dev" "$root/mnt"
cp "$(command -v busybox)" "$root/bin/busybox"
for applet in sh mount umount mkdir sync poweroff rm
do
    ln -s busybox "$root/bin/$applet"
done
cp "$helper" "$root/bin/appendfat-fixture"
cp "$repo/tests/qemu-reserve-ahead-init" "$root/init"
chmod +x "$root/init" "$root/bin/appendfat-fixture"

appendfat_make_initramfs "$root" "$initramfs"

set +e
timeout 240s qemu-system-x86_64 \
    -machine accel=tcg \
    -m 512M \
    -smp 2 \
    -nographic \
    -no-reboot \
    -kernel "$linux_tree/arch/x86/boot/bzImage" \
    -initrd "$initramfs" \
    -append 'console=ttyS0 rdinit=/init panic=-1' \
    -drive "file=$normal_image,format=raw,if=virtio" \
    -drive "file=$near_full_image,format=raw,if=virtio" \
    > "$qemu_log" 2>&1
qemu_status=$?
set -e

cat "$qemu_log"
grep -F APPENDFAT_QEMU_RESERVE_AHEAD_PASS "$qemu_log"
grep -F 'APPENDFAT_RESERVATION event=claim' "$qemu_log"
grep -F 'APPENDFAT_RESERVATION event=release' "$qemu_log"
grep -F 'APPENDFAT_RESERVATION event=shutdown-release' "$qemu_log"
grep -F 'APPENDFAT_RESERVATION event=shutdown-release' "$qemu_log" |
    grep -F 'owners=0 owner_refs=0'

if [ "$qemu_status" -ne 0 ] && [ "$qemu_status" -ne 124 ]; then
    printf '%s\n' "qemu exited unexpectedly: $qemu_status" >&2
    exit "$qemu_status"
fi

# Validate the final, stock-vfat-readable FAT chains directly.  The guest
# checks live-inode accounting before remount; these checks deliberately do
# not rely on stat output and also cover truncate and unlink cleanup.
appendfat_check_fat_chain "$normal_image" ::ahead.bin 5
appendfat_check_fat_chain "$normal_image" ::session-auto.bin 1
appendfat_check_fat_chain "$normal_image" ::session-mixed.bin 3
appendfat_check_fat_chain "$normal_image" ::session-rename-new.bin 1
appendfat_check_fat_chain "$normal_image" ::session-exchange-b.bin 1
appendfat_check_fat_chain "$normal_image" ::truncate.bin 1
if mshowfat -i "$normal_image" ::unlink.bin; then
    printf '%s\n' 'unlink.bin still has a FAT chain' >&2
    exit 1
fi
appendfat_check_fat_chain "$near_full_image" ::near-full.bin 2

fsck.fat -n -v "$normal_image"
fsck.fat -n -v "$near_full_image"
printf '%s\n' 'appendfat automatic reserve-ahead fixture passed'
