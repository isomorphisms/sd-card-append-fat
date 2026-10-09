#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' "usage: $0 /path/to/prepared-linux" >&2
    exit 2
fi

repo=$(git rev-parse --show-toplevel)
linux_tree=$1
pinned=238650ef6c7c7cca08e032527329424c9fbd70e5

actual=$(git -C "$linux_tree" rev-parse HEAD)
if [ "$actual" != "$pinned" ]; then
    printf '%s\n' "refusing unreviewed Linux base" >&2
    exit 1
fi

test -f "$linux_tree/arch/x86/boot/bzImage" || {
    printf '%s\n' 'prepared bzImage missing; run qemu-keep-size.sh first' >&2
    exit 1
}
test -r "$linux_tree/arch/x86/boot/bzImage" || {
    printf '%s\n' 'prepared bzImage is not readable' >&2
    exit 1
}

for command in busybox "${ICK:?Set ICK to the qualified native compiler}" cpio fsck.fat mkfs.fat qemu-system-x86_64 timeout truncate
do
    command -v "$command" >/dev/null 2>&1 || {
        printf '%s\n' "missing required command: $command" >&2
        exit 1
    }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/appendfat-keep-size-phase.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

helper=$work/fallocate-keep-size
fat_image=$work/fat.img

"${ICK:?Set ICK to the qualified native compiler}" ${ICK_FLAGS:--fno-link-libatomic} -static -O2 -Wall -Wextra -Werror \
    "$repo/tests/fallocate-keep-size.c" -o "$helper" -Wl,--start-group -lc -lgcc_eh -Wl,--end-group

truncate -s 64M "$fat_image"
mkfs.fat -F 32 -n APPRESERVE "$fat_image"

build_initramfs()
{
    init_source=$1
    phase=$2
    root=$work/root-$phase
    archive=$work/initramfs-$phase.cpio.gz

    mkdir -p "$root/bin" "$root/proc" "$root/sys" "$root/dev" "$root/mnt"
    cp "$(command -v busybox)" "$root/bin/busybox"
    cp "$helper" "$root/bin/fallocate-keep-size"
    for applet in sh mount umount mkdir cat sync poweroff grep ls
    do
        ln -s busybox "$root/bin/$applet"
    done
    cp "$repo/tests/$init_source" "$root/init"
    chmod +x "$root/init"

    (
        cd "$root"
        find . -print0 | cpio --null -ov --format=newc | gzip -9
    ) > "$archive"

    printf '%s\n' "$archive"
}

run_phase()
{
    archive=$1
    sentinel=$2
    phase=$3
    qemu_log=$work/qemu-$phase.log

    set +e
    timeout 120s qemu-system-x86_64 \
        -machine accel=tcg \
        -m 512M \
        -smp 2 \
        -nographic \
        -no-reboot \
        -kernel "$linux_tree/arch/x86/boot/bzImage" \
        -initrd "$archive" \
        -append 'console=ttyS0 rdinit=/init panic=-1' \
        -drive "file=$fat_image,format=raw,if=virtio" \
        > "$qemu_log" 2>&1
    qemu_status=$?
    set -e

    cat "$qemu_log"
    grep -F "$sentinel" "$qemu_log"

    if [ "$qemu_status" -ne 0 ] && [ "$qemu_status" -ne 124 ]; then
        printf '%s\n' "qemu phase $phase exited unexpectedly: $qemu_status" >&2
        exit "$qemu_status"
    fi
}

run_fsck()
{
    phase=$1
    fsck_log=$work/fsck-$phase.log

    set +e
    fsck.fat -n -v "$fat_image" > "$fsck_log" 2>&1
    fsck_status=$?
    set -e

    cat "$fsck_log"
    printf 'APPENDFAT_KEEP_SIZE_FSCK_%s_STATUS=%s\n' "$phase" "$fsck_status"

    if [ "$fsck_status" -ne 0 ]; then
        printf '%s\n' "fsck.fat rejected keep-size phase $phase" >&2
        exit "$fsck_status"
    fi
}

reserve_initramfs=$(build_initramfs qemu-fallocate-reserve-init reserve)
run_phase "$reserve_initramfs" APPENDFAT_KEEP_SIZE_RESERVE_PASS reserve

echo '== fsck after unused reservation was cleanly unmounted =='
run_fsck AFTER_RESERVE

partial_initramfs=$(build_initramfs qemu-fallocate-consume-init partial)
run_phase "$partial_initramfs" APPENDFAT_KEEP_SIZE_CONSUME_PASS partial

echo '== fsck after partial logical consumption =='
run_fsck AFTER_PARTIAL_CONSUME

full_initramfs=$(build_initramfs qemu-fallocate-full-consume-init full)
run_phase "$full_initramfs" APPENDFAT_KEEP_SIZE_FULL_CONSUME_PASS full

echo '== fsck after full logical consumption =='
run_fsck AFTER_FULL_CONSUME

printf '%s\n' 'APPENDFAT_KEEP_SIZE_PHASE_CHARACTERIZATION_PASS'
