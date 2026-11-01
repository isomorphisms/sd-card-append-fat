#!/bin/sh
set -eu

repo=$(git rev-parse --show-toplevel)
fixtures=$repo/tests/fixtures/qemu-reserve-ahead-measurement
parser=$repo/tests/qemu-reserve-ahead-measurement-parse.awk
work=$(mktemp -d "${TMPDIR:-/tmp}/appendfat-measure-parser.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

parse_complete()
{
    awk \
        -v expected_run_id=baseline-captured \
        -v expected_variant=baseline \
        -v expected_policy_clusters=1 \
        -v expected_alloc_calls=1 \
        -f "$parser" \
        "$fixtures/complete-receipt.txt" "$fixtures/complete-kernel.txt" \
        > "$work/complete.summary"
    grep -Fq 'variant=baseline' "$work/complete.summary"
    grep -Fq 'logical_size=32768' "$work/complete.summary"
}

reject()
{
    receipt=$1
    kernel=$2
    expected_alloc_calls=${3:-1}

    if awk \
        -v expected_run_id=baseline-captured \
        -v expected_variant=baseline \
        -v expected_policy_clusters=1 \
        -v expected_alloc_calls="$expected_alloc_calls" \
        -f "$parser" "$receipt" "$kernel" \
        > "$work/rejected.summary" 2> "$work/rejected.error"; then
        printf '%s\n' "accepted malformed measurement receipt: $receipt" >&2
        exit 1
    fi
}

parse_complete
reject "$fixtures/captured-console-split.txt" "$fixtures/complete-kernel.txt"
reject "$fixtures/duplicate-receipt.txt" "$fixtures/complete-kernel.txt"
reject "$fixtures/truncated-receipt.txt" "$fixtures/complete-kernel.txt"
reject "$fixtures/complete-receipt.txt" "$fixtures/cross-run-kernel.txt"
reject "$fixtures/complete-receipt.txt" "$fixtures/baseline-16-kernel.txt" 64
printf '%s\n' 'appendfat reserve-ahead measurement parser regressions passed'
