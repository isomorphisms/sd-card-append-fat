#!/bin/sh
set -eu

repo=$(git rev-parse --show-toplevel)

fail()
{
    printf 'FAIL  %s\n' "$*" >&2
    exit 1
}

require()
{
    pattern=$1
    file=$2
    grep -F "$pattern" "$file" >/dev/null ||
        fail "$file is missing required workflow contract: $pattern"
}

refuse()
{
    pattern=$1
    file=$2
    if grep -F "$pattern" "$file" >/dev/null; then
        fail "$file contains forbidden broad workflow route: $pattern"
    fi
}

workflows='
.github/workflows/appendfat-mv.yml
.github/workflows/qemu-fat-equivalence.yml
.github/workflows/qemu-keep-size.yml
.github/workflows/qemu-reserve-ahead.yml
.github/workflows/qemu-reserve-ahead-measurement.yml
.github/workflows/qemu-fat-matrix.yml
.github/workflows/qemu-module-load.yml
.github/workflows/qemu-power-cut.yml
.github/workflows/workflow-routing.yml
'

qemu_workflows='
.github/workflows/qemu-fat-equivalence.yml
.github/workflows/qemu-keep-size.yml
.github/workflows/qemu-reserve-ahead.yml
.github/workflows/qemu-fat-matrix.yml
.github/workflows/qemu-module-load.yml
.github/workflows/qemu-power-cut.yml
'

for relative in $workflows
do
    file="$repo/$relative"
    require '  push:' "$file"
    require '    branches:' "$file"
    require '      - main' "$file"
    require '  pull_request:' "$file"
    require 'concurrency:' "$file"
    require 'group: ${{ github.repository }}-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}' "$file"
    require 'cancel-in-progress: true' "$file"
done

for relative in $qemu_workflows
do
    file="$repo/$relative"
    require "'fs/appendfat/**'" "$file"
    require "'scripts/install-appendfat-into-linux.sh'" "$file"
    refuse "'tests/**'" "$file"
    refuse "'scripts/**'" "$file"
    refuse "'tools/appendfat_mv.c'" "$file"
    refuse "'tests/physical-sd-readonly-preflight.sh'" "$file"
    refuse "'tests/physical-appendfat-mv-scratch.sh'" "$file"
    refuse "'tests/physical-phone-appendfat-mv-acceptance.sh'" "$file"
done

for relative in \
    .github/workflows/qemu-keep-size.yml \
    .github/workflows/qemu-reserve-ahead.yml \
    .github/workflows/qemu-reserve-ahead-measurement.yml \
    .github/workflows/qemu-fat-matrix.yml \
    .github/workflows/qemu-module-load.yml \
    .github/workflows/qemu-power-cut.yml
do
    require "'tests/qemu-common.sh'" "$repo/$relative"
done

require "'tests/qemu-fat-equivalence.sh'" "$repo/.github/workflows/qemu-fat-equivalence.yml"
require "'tests/qemu-fat-equivalence-init'" "$repo/.github/workflows/qemu-fat-equivalence.yml"

require "'tests/qemu-keep-size.sh'" "$repo/.github/workflows/qemu-keep-size.yml"
require "'tests/qemu-keep-size-characterization.sh'" "$repo/.github/workflows/qemu-keep-size.yml"
require "'tests/fallocate-keep-size.c'" "$repo/.github/workflows/qemu-keep-size.yml"
require "'tests/qemu-keep-size-init'" "$repo/.github/workflows/qemu-keep-size.yml"
require "'tests/qemu-fallocate-reserve-init'" "$repo/.github/workflows/qemu-keep-size.yml"
require "'tests/qemu-fallocate-consume-init'" "$repo/.github/workflows/qemu-keep-size.yml"
require "'tests/qemu-fallocate-full-consume-init'" "$repo/.github/workflows/qemu-keep-size.yml"

require "'tests/qemu-reserve-ahead.sh'" "$repo/.github/workflows/qemu-reserve-ahead.yml"
require "'tests/qemu-reserve-ahead-init'" "$repo/.github/workflows/qemu-reserve-ahead.yml"
require "'tests/fallocate-keep-size.c'" "$repo/.github/workflows/qemu-reserve-ahead.yml"

require "'tests/qemu-reserve-ahead-measurement.sh'" "$repo/.github/workflows/qemu-reserve-ahead-measurement.yml"
require "'tests/qemu-reserve-ahead-measurement-init'" "$repo/.github/workflows/qemu-reserve-ahead-measurement.yml"
require "'tests/fallocate-keep-size.c'" "$repo/.github/workflows/qemu-reserve-ahead-measurement.yml"

require "'tests/qemu-fat-matrix.sh'" "$repo/.github/workflows/qemu-fat-matrix.yml"
require "'tests/qemu-fat-matrix-init'" "$repo/.github/workflows/qemu-fat-matrix.yml"

require "'tests/qemu-module-load.sh'" "$repo/.github/workflows/qemu-module-load.yml"
require "'tests/qemu-module-load-init'" "$repo/.github/workflows/qemu-module-load.yml"

require "'tests/qemu-power-cut.sh'" "$repo/.github/workflows/qemu-power-cut.yml"
require "'tests/qemu-power-cut-write-init'" "$repo/.github/workflows/qemu-power-cut.yml"
require "'tests/qemu-power-cut-verify-init'" "$repo/.github/workflows/qemu-power-cut.yml"

require "'tests/physical-phone-appendfat-mv-acceptance.sh'" "$repo/.github/workflows/appendfat-mv.yml"

printf '%s\n' 'PASS  workflow routing contract'
