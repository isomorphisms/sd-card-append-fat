# Userspace division producer

Six owned userspace/test divisions now use literal `÷`: arena growth, the
mover fault-injection delay, and the four keep-size characterization divisions.
ICK c61e448251744a2f40ad743ebef1a027bdcd2f9d retains their existing unsigned
and signed arithmetic semantics.

The host arena/mover tests and useful behavioral mutants require explicit
`ICK`. The shared host producer at ai-ci
015cc7901ae0b3ad262b476f24e129b53c56db95 supplies that compiler; its required
`-fno-link-libatomic` option is retained. The QEMU scripts compile their owned
static userspace helper with ICK while pinned Linux itself keeps Kbuild's
existing compiler and source. Imported FAT/kernel/reference source is intact.
The static helper explicitly links the declared GCC runtime unwind archive
with libc; this preserves the standalone initramfs executable.
The pre-existing Python fixture writer in the arena test remains unchanged
language debt.

The maintained Android arena pair (API26 ARMv7/AArch64) and mover probe
(API24 ARMv7/Thumb-2) compile owned C through the same exact-source ICK
frontend. NDK r27c assembles and links it. The shared Makefile supplies target
and builtin-header metadata, and both Android API macros agree. No NDK C
fallback is selected for these userspace producers.
The reusable Android command-line arena consumer uses the same producer.
Strict ICK warnings also exposed a bounded cleanup-path suffix truncation in
the Android harness; its temporary buffer now includes room for `.used` and
`.lock` beyond the existing arena pathname capacity.

Local validation: the host arena library/CLI, full mover fault-injection suite
and all six dangerous behavioral mutants pass. Both API26 arena app libraries,
the ARMv7 arena CLI and API24 Thumb-2 mover compile, assemble and link with
actual r27c. The static keep-size helper links and executes keep-size/size/
truncate probes on newly created host scratch files. This does not replace
the existing kernel/QEMU matrix and persistence checks.

The shared C-stage contract is required in host jobs. Existing workflow
path routing, mutation requirements and physical scratch arming are retained.
No physical SD-card operation, kernel mount or storage deployment is performed
by this syntax migration. The existing sandbox APK retains its declared test
signer procedure; no production identity or release is introduced.
