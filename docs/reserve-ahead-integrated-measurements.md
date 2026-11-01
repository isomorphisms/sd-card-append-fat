# Integrated reserve-ahead measurement receipt

Evidence: local x86-64 QEMU TCG, two vCPUs, 512 MiB guest RAM, virtio block
device; not physical SD-card or Android evidence. Both repeats of each policy
started from byte-identical copies of the same FAT32 template. The workload
wrote 64 clusters in 97-byte appends, synchronized, and sampled guest block
statistics before writing measurement receipts and kernel logs to the image.

Source: `7e5caf2fa1adc0f538cd029e8ed1f5195b3ef1ce`.
Filesystem tree: `23149ae8d3f4d1605df68d5444ebe8793a1e30c3`.
Linux: `238650ef6c7c7cca08e032527329424c9fbd70e5`.
The committed measurement guest, C workload, and fail-closed AWK parser were
used unchanged. The local build reused the pinned defconfig build and scoped
the policy/metric flags to AppendFAT's Kbuild directory. Both variants enabled
allocation metrics, reservation tracing, and test faults; all faults remained
disarmed. The only policy difference was `APPENDFAT_APPEND_AHEAD_CLUSTERS=1`
versus `4`.

| Measurement | Policy 1, repeats 1 / 2 | Policy 4, repeats 1 / 2 |
| --- | ---: | ---: |
| Allocator calls | 64 / 64 | 16 / 16 |
| Chain attachments | 64 / 64 | 16 / 16 |
| FAT-entry modifications | 127 / 127 | 127 / 127 |
| FAT buffer references | 127 / 127 | 31 / 31 |
| FAT mirror copies | 127 / 127 | 31 / 31 |
| FSINFO dirty notifications | 64 / 64 | 16 / 16 |
| Block write operations | 6 / 6 | 6 / 6 |
| Block sectors written | 68 / 68 | 68 / 68 |
| Logical bytes | 32,768 / 32,768 | 32,768 / 32,768 |
| Final allocated clusters | 64 / 64 | 64 / 64 |

Cluster size was 512 bytes. Each guest verified all content through stock vfat;
each image passed read-only `fsck.fat`. Independent `mshowfat` output for every
workload was `<3-66>`, a 64-cluster chain. That observation is specific to these
images and does not establish a general contiguity guarantee.

SHA-256 digests:

| Object | SHA-256 |
| --- | --- |
| Policy 1 kernel | `1e787729cf11bd7a76922e963f284bc30ac08bd1b83dadb258ae1180dcccef07` |
| Policy 4 kernel | `5465fa2ca2de3376ff9854a6c628bcbbada29d350bf126c4bd761c534f5991f2` |
| Shared initramfs | `f62d5e40f8654f5543b0441933615e97dd74813c0117e7a7ebd7514d9b211dd6` |
| Shared initial FAT image | `c8e497918d02b0e45e54974b8eed4068b60b2dd7d6392c15a671878ff0cde6a1` |

The inherited full-build reproduction entrypoint is
`tests/qemu-reserve-ahead-measurement.sh`, with two clean checkouts of the pinned
Linux revision as its arguments. Its hosted exact-head result is a separate
receipt from this local run and is recorded in the integration report. The
measurement parser rejects missing, duplicate, cross-run, truncated, or
structurally inconsistent receipts.

These measurements show fewer allocator/attachment and buffer-processing
operations. They show no block-write or sector reduction in this workload and
establish no NAND-wear or controller-placement result.
