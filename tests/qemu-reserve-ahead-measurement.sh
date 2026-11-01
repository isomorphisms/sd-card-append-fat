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

sh "$repo/tests/qemu-reserve-ahead-measurement-parser.sh"
appendfat_require_commands awk busybox cc cpio cp fsck.fat mkfs.fat mtype mshowfat \
    qemu-system-x86_64 sha256sum timeout truncate

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

if [ -n "${APPENDFAT_MEASUREMENT_OUTPUT_DIR:-}" ]; then
    # Refuse an existing directory: receipts and images belong to one fresh run.
    mkdir "$APPENDFAT_MEASUREMENT_OUTPUT_DIR"
    work=$APPENDFAT_MEASUREMENT_OUTPUT_DIR
else
    work=$(mktemp -d "${TMPDIR:-/tmp}/appendfat-append-measure.XXXXXX")
    trap 'rm -rf "$work"' EXIT HUP INT TERM
fi

template=$work/template.img
root=$work/initramfs
initramfs=$work/initramfs.cpio.gz
helper=$work/appendfat-fixture
source_sha=$(git -C "$repo" rev-parse HEAD)
filesystem_source_tree_sha=$(git -C "$repo" rev-parse HEAD:fs/appendfat)
a1_source_sha=eb98ac19e04350dede4ee53a9fd778eda8482f8f

truncate -s 64M "$template"
mkfs.fat -F 32 -n AFMEASURE "$template"
template_sha=$(sha256sum "$template" | awk '{ print $1 }')

cc -O2 -static -Wall -Wextra -Werror \
    "$repo/tests/fallocate-keep-size.c" \
    -o "$helper"

mkdir -p "$root/bin" "$root/proc" "$root/sys" "$root/dev" "$root/mnt"
cp "$(command -v busybox)" "$root/bin/busybox"
for applet in sh mount umount mkdir sync poweroff dmesg
do
    ln -s busybox "$root/bin/$applet"
done
cp "$helper" "$root/bin/appendfat-fixture"
cp "$repo/tests/qemu-reserve-ahead-measurement-init" "$root/init"
chmod +x "$root/init" "$root/bin/appendfat-fixture"
appendfat_make_initramfs "$root" "$initramfs"

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

same_measurement_counts()
{
    first=$1
    second=$2

    for key in reserve_calls alloc_calls attach_calls fat_updates \
        fat_buffer_refs mirror_buffer_copies fsinfo_dirty_calls logical_size \
        logical_blocks cluster_bytes target_bytes
    do
        [ "$(value "$first" "$key")" = "$(value "$second" "$key")" ] || {
            printf '%s\n' "measurement count changed between repeats: $key" >&2
            exit 1
        }
    done
}

run_variant()
{
    variant=$1
    policy_clusters=$2
    linux_tree=$3
    repetition=$4
    image=$work/$variant-$repetition.img
    console=$work/$variant-$repetition.console.log
    receipt=$work/$variant-$repetition.receipt
    kernel_record=$work/$variant-$repetition.kernel.log
    summary=$work/$variant-$repetition.summary
    host_receipt=$work/$variant-$repetition.host-receipt
    kernel_sha=$(git -C "$linux_tree" rev-parse HEAD)
    expected_alloc_calls=$((64 / policy_clusters))

    cp "$template" "$image"
    initial_image_sha=$(sha256sum "$image" | awk '{ print $1 }')
    [ "$initial_image_sha" = "$template_sha" ] || {
        printf '%s\n' 'variant did not start from the template FAT image' >&2
        exit 1
    }
    run_id=$variant-$repetition-$template_sha

    set +e
    timeout 240s qemu-system-x86_64 \
        -machine accel=tcg \
        -m 512M \
        -smp 2 \
        -nographic \
        -no-reboot \
        -kernel "$linux_tree/arch/x86/boot/bzImage" \
        -initrd "$initramfs" \
        -append "console=ttyS0 rdinit=/init panic=-1 appendfat_measure_run_id=$run_id appendfat_measure_variant=$variant appendfat_measure_policy_clusters=$policy_clusters" \
        -drive "file=$image,format=raw,if=virtio" \
        > "$console" 2>&1
    status=$?
    set -e

    grep -F APPENDFAT_QEMU_APPEND_MEASUREMENT_PASS "$console"
    if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
        printf '%s\n' "qemu $variant repetition $repetition exited unexpectedly: $status" >&2
        exit "$status"
    fi

    fsck.fat -n -v "$image"
    mtype -i "$image" ::AFWORKLD.TXT > "$receipt"
    mtype -i "$image" ::AFKERNL.TXT > "$kernel_record"
    awk \
        -v expected_run_id="$run_id" \
        -v expected_variant="$variant" \
        -v expected_policy_clusters="$policy_clusters" \
        -v expected_alloc_calls="$expected_alloc_calls" \
        -f "$repo/tests/qemu-reserve-ahead-measurement-parse.awk" \
        "$receipt" "$kernel_record" > "$summary"

    final_image_sha=$(sha256sum "$image" | awk '{ print $1 }')
    mshowfat -i "$image" ::workload.bin > "$work/$variant-$repetition.fat-chain"
    allocation_clusters=$(awk '
        {
            for (i = 2; i <= NF; i++) {
                if ($i !~ /^<[0-9]+(-[0-9]+)?>$/) exit 1
                entry = $i
                gsub(/[<>]/, "", entry)
                n = split(entry, ends, "-")
                clusters += n == 1 ? 1 : ends[2] - ends[1] + 1
            }
            records++
        }
        END { if (records != 1 || clusters != 64) exit 1; print clusters }
    ' "$work/$variant-$repetition.fat-chain")
    {
        printf '%s\n' "measurement_source_sha=$source_sha"
        printf '%s\n' "filesystem_source_tree_sha=$filesystem_source_tree_sha"
        printf '%s\n' "a1_source_sha=$a1_source_sha"
        printf '%s\n' 'a1_repair_patch_sha256=8d6d50b8543204bbc889e00f310e530f010565935db9971873b1997cb0146295'
        printf '%s\n' "kernel_sha=$kernel_sha"
        printf '%s\n' "kernel_image_sha256=$(sha256sum "$linux_tree/arch/x86/boot/bzImage" | awk '{ print $1 }')"
        printf '%s\n' "initramfs_sha256=$(sha256sum "$initramfs" | awk '{ print $1 }')"
        printf '%s\n' "variant=$variant"
        printf '%s\n' "policy_clusters=$policy_clusters"
        printf '%s\n' "repetition=$repetition"
        printf '%s\n' "template_image_sha256=$template_sha"
        printf '%s\n' "initial_image_sha256=$initial_image_sha"
        printf '%s\n' "final_image_sha256=$final_image_sha"
        printf '%s\n' "final_allocation_clusters=$allocation_clusters"
        cat "$summary"
    } > "$host_receipt"
    cat "$host_receipt"
}

run_variant baseline 1 "$baseline_linux" 1
run_variant baseline 1 "$baseline_linux" 2
run_variant ahead 4 "$ahead_linux" 1
run_variant ahead 4 "$ahead_linux" 2

baseline_first=$work/baseline-1.summary
baseline_second=$work/baseline-2.summary
ahead_first=$work/ahead-1.summary
ahead_second=$work/ahead-2.summary

same_measurement_counts "$baseline_first" "$baseline_second"
same_measurement_counts "$ahead_first" "$ahead_second"

baseline_alloc=$(value "$baseline_first" alloc_calls)
ahead_alloc=$(value "$ahead_first" alloc_calls)
baseline_attach=$(value "$baseline_first" attach_calls)
ahead_attach=$(value "$ahead_first" attach_calls)
baseline_updates=$(value "$baseline_first" fat_updates)
ahead_updates=$(value "$ahead_first" fat_updates)
baseline_buffers=$(value "$baseline_first" fat_buffer_refs)
ahead_buffers=$(value "$ahead_first" fat_buffer_refs)
baseline_fsinfo=$(value "$baseline_first" fsinfo_dirty_calls)
ahead_fsinfo=$(value "$ahead_first" fsinfo_dirty_calls)
baseline_size=$(value "$baseline_first" logical_size)
ahead_size=$(value "$ahead_first" logical_size)

# These are semantic assertions, not values to weaken for a passing run.
[ "$baseline_alloc" -eq 64 ]
[ "$ahead_alloc" -eq 16 ]
[ "$baseline_attach" -eq 64 ]
[ "$ahead_attach" -eq 16 ]
[ "$baseline_updates" -eq "$ahead_updates" ]
[ "$ahead_buffers" -lt "$baseline_buffers" ]
[ "$ahead_fsinfo" -lt "$baseline_fsinfo" ]
[ "$baseline_size" -eq "$ahead_size" ]
printf '%s\n' 'APPENDFAT_APPEND_MEASUREMENT_COMPARISON_PASS'
