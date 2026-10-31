#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf '%s\n' "usage: $0 /path/to/baseline-linux /path/to/ahead-linux" >&2
    exit 2
fi

repo=$(git rev-parse --show-toplevel)
baseline_linux=$1
ahead_linux=$2

. "$repo/tests/qemu-common.sh"

appendfat_require_commands awk busybox cc cpio cp fsck.fat mkfs.fat qemu-system-x86_64 timeout truncate

(
    export APPENDFAT_ALLOC_METRICS=1
    export APPENDFAT_APPEND_AHEAD_CLUSTERS=1
    appendfat_prepare_linux "$repo" "$baseline_linux" builtin
)
(
    export APPENDFAT_ALLOC_METRICS=1
    export APPENDFAT_APPEND_AHEAD_CLUSTERS=4
    appendfat_prepare_linux "$repo" "$ahead_linux" builtin
)

work=$(mktemp -d "${TMPDIR:-/tmp}/appendfat-append-measure.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

template=$work/template.img
baseline_image=$work/baseline.img
ahead_image=$work/ahead.img
root=$work/initramfs
initramfs=$work/initramfs.cpio.gz
helper=$work/appendfat-fixture

truncate -s 64M "$template"
mkfs.fat -F 32 -n AFMEASURE "$template"
cp "$template" "$baseline_image"
cp "$template" "$ahead_image"

cc -O2 -static -Wall -Wextra -Werror \
    "$repo/tests/fallocate-keep-size.c" \
    -o "$helper"

mkdir -p "$root/bin" "$root/proc" "$root/sys" "$root/dev" "$root/mnt"
cp "$(command -v busybox)" "$root/bin/busybox"
for applet in sh mount umount mkdir sync poweroff
do
    ln -s busybox "$root/bin/$applet"
done
cp "$helper" "$root/bin/appendfat-fixture"
cp "$repo/tests/qemu-reserve-ahead-measurement-init" "$root/init"
chmod +x "$root/init" "$root/bin/appendfat-fixture"

appendfat_make_initramfs "$root" "$initramfs"

run_variant()
{
    variant=$1
    linux_tree=$2
    image=$3
    log=$work/$variant.log

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
        -drive "file=$image,format=raw,if=virtio" \
        > "$log" 2>&1
    status=$?
    set -e

    cat "$log"
    grep -F APPENDFAT_QEMU_APPEND_MEASUREMENT_PASS "$log"

    if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
        printf '%s\n' "qemu $variant exited unexpectedly: $status" >&2
        exit "$status"
    fi

    fsck.fat -n -v "$image"
}

summarize_variant()
{
    variant=$1
    log=$2
    output=$3

    awk -v variant="$variant" '
        /APPENDFAT_APPEND_MEASURE_BEGIN/ { inside = 1; next }
        /APPENDFAT_APPEND_MEASURE_END/ { inside = 0 }
        inside && /APPENDFAT_ALLOC_METRIC alloc requested=/ {
            alloc_calls++
            for (i = 1; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == "fat_updates") allocator_fat_updates += pair[2]
                if (pair[1] == "fat_buffers") fat_buffer_refs += pair[2]
                if (pair[1] == "mirror_buffers") mirror_buffer_copies += pair[2]
                if (pair[1] == "fsinfo_dirty_calls") fsinfo_dirty_calls += pair[2]
            }
        }
        inside && /APPENDFAT_ALLOC_METRIC attach clusters=/ {
            attach_calls++
            for (i = 1; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == "tail_link") tail_links += pair[2]
                if (pair[1] == "fat_buffers") fat_buffer_refs += pair[2]
                if (pair[1] == "mirror_buffers") mirror_buffer_copies += pair[2]
            }
        }
        inside && /APPENDFAT_APPEND_WORKLOAD/ {
            for (i = 1; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == "vda_write_ops") write_ops = pair[2]
                if (pair[1] == "vda_write_sectors") write_sectors = pair[2]
                if (pair[1] == "size") logical_size = pair[2]
                if (pair[1] == "blocks") blocks = pair[2]
                if (pair[1] == "cluster_bytes") cluster_bytes = pair[2]
            }
        }
        END {
            printf "variant=%s alloc_calls=%d attach_calls=%d fat_updates=%d fat_buffer_refs=%d mirror_buffer_copies=%d fsinfo_dirty_calls=%d write_ops=%d write_sectors=%d logical_size=%d blocks=%d cluster_bytes=%d\n",
                variant, alloc_calls, attach_calls,
                allocator_fat_updates + tail_links,
                fat_buffer_refs, mirror_buffer_copies, fsinfo_dirty_calls,
                write_ops, write_sectors, logical_size, blocks, cluster_bytes
        }
    ' "$log" > "$output"

    cat "$output"
}

value()
{
    file=$1
    key=$2
    awk -v key="$key" '{
        for (i = 1; i <= NF; i++) {
            split($i, pair, "=")
            if (pair[1] == key) {
                print pair[2]
                exit
            }
        }
    }' "$file"
}

run_variant baseline "$baseline_linux" "$baseline_image"
run_variant ahead "$ahead_linux" "$ahead_image"

summarize_variant baseline "$work/baseline.log" "$work/baseline.summary"
summarize_variant ahead "$work/ahead.log" "$work/ahead.summary"

baseline_alloc=$(value "$work/baseline.summary" alloc_calls)
ahead_alloc=$(value "$work/ahead.summary" alloc_calls)
baseline_attach=$(value "$work/baseline.summary" attach_calls)
ahead_attach=$(value "$work/ahead.summary" attach_calls)
baseline_updates=$(value "$work/baseline.summary" fat_updates)
ahead_updates=$(value "$work/ahead.summary" fat_updates)
baseline_buffers=$(value "$work/baseline.summary" fat_buffer_refs)
ahead_buffers=$(value "$work/ahead.summary" fat_buffer_refs)
baseline_fsinfo=$(value "$work/baseline.summary" fsinfo_dirty_calls)
ahead_fsinfo=$(value "$work/ahead.summary" fsinfo_dirty_calls)
baseline_size=$(value "$work/baseline.summary" logical_size)
ahead_size=$(value "$work/ahead.summary" logical_size)

[ "$baseline_alloc" -eq 64 ]
[ "$ahead_alloc" -eq 16 ]
[ "$baseline_attach" -eq 64 ]
[ "$ahead_attach" -eq 16 ]
[ "$baseline_updates" -eq "$ahead_updates" ]
[ "$ahead_buffers" -lt "$baseline_buffers" ]
[ "$ahead_fsinfo" -lt "$baseline_fsinfo" ]
[ "$baseline_size" -eq "$ahead_size" ]

printf '%s\n' 'APPENDFAT_APPEND_MEASUREMENT_COMPARISON_PASS'
