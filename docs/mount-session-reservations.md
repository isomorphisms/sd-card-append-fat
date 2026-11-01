# AppendFAT reservation ownership and recovery

Production changes remain confined to `fs/appendfat`. The upstream FAT import
and stock `fs/fat` are unchanged. Linux source remains pinned to
`238650ef6c7c7cca08e032527329424c9fbd70e5`.

## Allocation and file length

An extending write passes through `__fat_get_block`. If the block lies in
already allocated capacity, no allocation takes place. At exhaustion,
`appendfat_add_clusters` asks the FAT allocator for one bounded batch, attaches
the prepared chain once, and increases `i_blocks` by the number of attached
clusters. Only ENOSPC on a speculative batch triggers a one-cluster retry.
Other errors propagate. A failed attachment releases the unattached chain.

The default batch is `MAX_BUF_PER_PAGE / 2`: four clusters on the qualified
4 KiB-page kernel. Explicit KEEP_SIZE and automatic allocation use the same
attachment and ownership path. This is not a contiguity guarantee.

Three quantities have different meanings:

| Quantity | Meaning |
| --- | --- |
| `i_blocks << 9` | Capacity accounted to this live inode, including reservations. |
| `i_size` | Logical length visible to readers. Speculative bytes are never exposed. |
| Successfully synchronized data | The durability boundary established by fsync/sync and a successful device flush; neither capacity nor dirty logical length proves durability. |

`mmu_private` is the inherited FAT initialized/mapped write frontier. Despite
the inherited field comment, it is neither total reserved capacity nor a
persisted durable-written-extent record. No new on-disk metadata is introduced.

## Mount ownership

Each linked regular inode with unused clusters has at most one list node and
one superblock-owned inode reference. Descriptor count and dentry-cache
retention do not determine its lifetime. Cache reclamation cannot evict a
reservation owner. Full consumption and truncate reconcile that reference;
rename and exchange retain the inode's ownership.

Unlink and replacement release unused capacity and the mount's reference.
Further writes to an open orphan cannot acquire a new mount reference. Its
remaining logical data and later allocations follow ordinary final-close
eviction. The inode lock serializes file changes; `truncate_lock` protects
mapping readers during tail release; the reservation mutex protects only list
membership and reference accounting. `iput` runs outside that mutex.

Clean teardown drains the ownership list before `kill_block_super`. Read-only
remount drains it while writes remain permitted and then synchronizes cleanup.
A later read-write remount starts without those unused reservations. No memory
object is allocated separately for each reservation; list state is embedded in
the inode. Test traces report list owners/references and require a zero balance
at shutdown.

## Recovery limits

A power cut loses all mount-owned references. A reachable FAT chain may still
extend beyond the committed directory length. Loading the directory entry does
not recreate a reservation: it initializes ordinary logical-size accounting.
Before the first new allocation on that inode, AppendFAT traverses the actual
chain. A shorter-than-required chain returns EIO. An overlong chain is trimmed
to committed logical length before allocation and attachment can proceed. The
normal inode lock serializes this check, and errors propagate to the caller.

This normalization handles a reachable excess tail. It does not discover
unreachable chains, choose between conflicting FAT mirrors, or make arbitrary
metadata writes atomic. Those states require ordinary offline FAT recovery.
The power-cut gate separately checks synchronized content after a real QEMU
SIGKILL and explicit repair of a disposable image. The recovery-state fixture
changes a directory length on an unmounted disposable FAT32 image and checks
subsequent append, exact content, clean teardown, and stock-vfat compatibility.
These are distinct evidence classes, not exhaustive crash consistency proof.

## Regression and performance evidence

The reserve-ahead gate retains its four-cluster initial assertion and the
one-cluster-policy mutation must fail there. FAT filesystem identity is checked
before interpreting statfs geometry; this prevents an omitted mount from
measuring initramfs allocation. The original preserved fixture omitted that
mount; the retained `ee0e864` recovery restores it.

Success markers use the C fixture's `kernel-marker` command, which writes one
record through `/dev/kmsg`. In hosted run `41239198324`, printk metrics split
the userspace `APPENDFAT_KEEP_SIZE_FULL_CONSUME_PASS` line despite successful
guest assertions and poweroff. Serializing the marker with kernel records
repairs that capture race; all content, allocation, and fsck assertions remain.

Lifetime regressions exercise forced cache reclamation, independent concurrent
append descriptions with exact byte counts, close ordering, replacement,
unlink followed by another refill, truncate, mixed KEEP_SIZE, rename/exchange,
and read-only remount. `APPENDFAT_TEST_FAULTS` enables one-shot pre-allocation
ENOMEM, partial-allocation EIO, pre-mirror EIO, and post-allocation/pre-attachment
EIO controls only in test builds. A fifth control reports an attachment error
after the old tail's primary and mirror entries have been changed, exercising
the actual tail-link restoration path before the new chain is freed.
Their regressions compare logical length, allocation, free-cluster counts,
and successful retry. They do not simulate a device that also fails rollback
writes or every instruction inside FAT mirroring.

The A/B measurement gate builds policy 1 and policy 4 from the same source,
starts each repeat from identical images, and validates independent guest
receipts and host FAT-chain counts. It records allocator/attachment counts,
FAT-entry changes, buffer references, mirror copies, FSINFO dirty notifications,
virtio writes/sectors, and final length/allocation. CPU and metadata-processing
reductions must be reported separately from block-device writes. No NAND wear,
controller-placement, or physical-contiguity claim follows from this gate.

The [integrated local A/B receipt](reserve-ahead-integrated-measurements.md)
records both repeats, all counters, and image/kernel/initramfs digests.

The requirement-to-test ledger is
[`reserve-complete-acceptance.tsv`](reserve-complete-acceptance.tsv). Current
head, CI URLs, measurements, and remaining blockers belong in the final
[integration report on the retained pull request](https://github.com/isomorphisms/sd-card-append-fat/pull/20).

## Physical boundary

The active Android target is SVITOO TAB_P10. No physical tablet or SD-card
acceptance follows from Linux/QEMU qualification. Cat Food must first establish
the tablet's actual removable storage, kernel support, and access privileges.
This campaign never formats, repairs, repartitions, mounts, or writes physical
media, replaces a running kernel, or modifies pre-existing user data.
