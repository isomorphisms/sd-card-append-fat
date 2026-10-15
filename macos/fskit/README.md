# AppendFAT on a Mac's internal SSD — FSKit

**Experimental, not yet mounted or accepted.** This is a real FSKit app
extension, not the Linux appendfat driver, not an SD-card path, and not
a claim to change APFS's physical allocation policy.

## Platform

- macOS 26+: FSKit supports `FSPathURLResource`; mount a dedicated source
  directory on the Mac's existing APFS filesystem as an FSKit volume.
- macOS 15.4–15.x: FSKit exists but the path-resource strategy here requires
  newer APIs. A virtual disk-image/block-resource version is possible, but
  not implemented here.
- No raw SSD access, formatting, partition changes, root, or kernel extension.

## Actual first filesystem slice

```text
Finder / Terminal / IB
      ↓
~/AppendFAT-mounted/append.log         (logical visible file)
      ↓
FSKit app extension (Swift API shell)
      ↓
AppendFATBridge.c
      ↓
lib/appendfat_arena.{c,h}              (parent PR #26)
      ↓
~/AppendFAT-source/append.arena         (physical APFS file)
~/AppendFAT-source/append.arena.used
~/AppendFAT-source/append.arena.lock
```

The mount exposes one file, `append.log`. Reads are permitted at any
offset. A write succeeds **only** when its offset equals the committed end;
the bridge takes the arena lock, appends, synchronizes data, and publishes the
new committed end. Stale-offset writes, arbitrary overwrite, truncate,
unlink, create, rename, and symlinks are refused. Metadata reports the
logical committed size, not the arena's trailing zero capacity.

This is not yet general-purpose POSIX storage. APFS copy-on-write can allocate
new blocks on rewrite. FSKit caching, O_APPEND propagation, Finder behavior,
real Mac extension activation and crash recovery are still acceptance gates.

## Local scratch experiment (only with the Mac owner's participation)

1. Record `sw_vers -productVersion`, `uname -m`, and `xcodebuild -version`.
   The path-backed extension requires macOS 26+ and a suitable Xcode SDK.
2. On a new disposable source directory, use an **ICK-qualified** build of
   the parent branch's `appendfat_arena` CLI to create the physical arena:
   `mkdir "$HOME/AppendFAT-source"`
   `appendfat_arena create "$HOME/AppendFAT-source/append.arena" 1048576`.
   All three backing paths must be absent beforehand; the CLI refuses to
   overwrite existing files. The macOS ICK build is not yet qualified.
3. Once the ICK Darwin core and link integration are qualified, open
   `macos/fskit/AppendFATFSKit.xcodeproj`, select scheme
   `AppendFATFSKit`, choose an appropriate signing team, build and launch
   the host app. Xcode must sign the extension with the
   `com.apple.developer.fskit.fsmodule` entitlement.
4. Enable AppendFATFSKitExtension at System Settings → General →
   Login Items & Extensions → File System Extensions.
5. Create an otherwise empty `~/AppendFAT-mounted` directory and run:
   `/sbin/mount -F -t appendfat "$HOME/AppendFAT-source" "$HOME/AppendFAT-mounted"`.
   The `-F` switch is required for this FSKit mount route.
6. Inspect `ls -l "$HOME/AppendFAT-mounted"`. In the disposable mount
   only, try `printf test >> "$HOME/AppendFAT-mounted/append.log"`,
   `cat "$HOME/AppendFAT-mounted/append.log"`, then
   `umount "$HOME/AppendFAT-mounted"`. Reopen the same source to verify
   the committed prefix. Stop immediately if either path resolves outside
   the dedicated scratch directories.

Do not expose the owner's home directory as the FSKit source. Do not
attempt destructive power-cut tests on a production SSD.

## SDK-only CI diagnostic

```sh
xcodebuild -project macos/fskit/AppendFATFSKit.xcodeproj \
  -scheme AppendFATFSKit -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_CFLAGS=-DAPPENDFAT_FSKIT_SDK_PROBE=1 build
```

This is **not** a signed install or mounted acceptance. An explicit `OTHER_CFLAGS=-DAPPENDFAT_FSKIT_SDK_PROBE=1` flag compiles
an ENOTSUP-only bridge, not the storage core, strictly to verify Apple FSKit
API compatibility. The default production path intentionally has unresolved
arena symbols until a Darwin Mach-O core object is supplied by ICK. Linux
core/bridge behavior is tested separately with the pinned ICK producer.
Release/merge is blocked until ICK produces Darwin arm64 and x86_64
objects through FP and independent ai-ci.

## Required acceptance

- Flexible Pipes envelope → Kitchen/Ike → independent ai-ci receipts;
  draft GitHub code is not releasable by itself.
- ICK-qualified macOS arm64/x86_64 builds, ABI and code-signing evidence.
- Real FSKit signed-extension activation, mount, logical EOF, write/read,
  concurrency, full arena, stale offsets, source-path confinement.
- Safe restart and fault-injection results on new scratch files only.
- APFS commit/directory-sync behavior and explicit statement of COW limits.
- Extension entitlement, security scope, no symlink escapes or unexpected
  reads/writes outside the dedicated source.

Apple references: https://developer.apple.com/documentation/fskit/ and
https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system
Parent PR: https://github.com/isomorphisms/sd-card-append-fat/pull/26
