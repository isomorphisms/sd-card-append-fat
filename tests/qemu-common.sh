#!/bin/sh

appendfat_pinned_linux=238650ef6c7c7cca08e032527329424c9fbd70e5

appendfat_require_commands()
{
    for appendfat_command in "$@"
    do
        command -v "$appendfat_command" >/dev/null 2>&1 || {
            printf '%s\n' "missing required command: $appendfat_command" >&2
            return 1
        }
    done
}

appendfat_prepare_linux()
{
    appendfat_repo=$1
    appendfat_linux_tree=$2
    appendfat_mode=$3

    if [ "${APPENDFAT_ALLOC_METRICS:-0}" = 1 ]; then
        export KCFLAGS="${KCFLAGS:+$KCFLAGS }-DAPPENDFAT_ALLOC_METRICS"
    fi
    if [ -n "${APPENDFAT_APPEND_AHEAD_CLUSTERS:-}" ]; then
        case "$APPENDFAT_APPEND_AHEAD_CLUSTERS" in
            *[!0-9]*|'')
                printf '%s\n' "invalid APPENDFAT_APPEND_AHEAD_CLUSTERS" >&2
                return 2
                ;;
            0)
                printf '%s\n' "APPENDFAT_APPEND_AHEAD_CLUSTERS must be positive" >&2
                return 2
                ;;
        esac
        export KCFLAGS="${KCFLAGS:+$KCFLAGS }-DAPPENDFAT_APPEND_AHEAD_CLUSTERS=$APPENDFAT_APPEND_AHEAD_CLUSTERS"
    fi

    appendfat_actual=$(git -C "$appendfat_linux_tree" rev-parse HEAD)
    if [ "$appendfat_actual" != "$appendfat_pinned_linux" ]; then
        printf '%s\n' "refusing unreviewed Linux base" >&2
        printf '%s\n' "expected: $appendfat_pinned_linux" >&2
        printf '%s\n' "actual:   $appendfat_actual" >&2
        return 1
    fi

    sh "$appendfat_repo/scripts/install-appendfat-into-linux.sh" "$appendfat_linux_tree"

    make -C "$appendfat_linux_tree" defconfig
    appendfat_config="$appendfat_linux_tree/scripts/config"
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable FAT_FS
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable VFAT_FS
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable MSDOS_FS
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --disable FAT_KUNIT_TEST
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --disable APPENDFAT_KUNIT_TEST
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable BLK_DEV_INITRD
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable DEVTMPFS
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable DEVTMPFS_MOUNT
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable VIRTIO
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable VIRTIO_PCI
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable VIRTIO_BLK
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable SERIAL_8250
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable SERIAL_8250_CONSOLE
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable NLS_CODEPAGE_437
    "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable NLS_ISO8859_1

    case "$appendfat_mode" in
        builtin)
            "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable APPENDFAT_VFAT_FS
            "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable APPENDFAT_MSDOS_FS
            ;;
        module)
            "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable MODULES
            "$appendfat_config" --file "$appendfat_linux_tree/.config" --enable MODULE_UNLOAD
            "$appendfat_config" --file "$appendfat_linux_tree/.config" --module APPENDFAT_VFAT_FS
            "$appendfat_config" --file "$appendfat_linux_tree/.config" --module APPENDFAT_MSDOS_FS
            ;;
        *)
            printf '%s\n' "unknown appendfat kernel mode: $appendfat_mode" >&2
            return 2
            ;;
    esac

    make -C "$appendfat_linux_tree" olddefconfig

    grep '^CONFIG_FAT_FS=y$' "$appendfat_linux_tree/.config"
    grep '^CONFIG_VFAT_FS=y$' "$appendfat_linux_tree/.config"
    grep '^CONFIG_MSDOS_FS=y$' "$appendfat_linux_tree/.config"
    grep '^CONFIG_VIRTIO_BLK=y$' "$appendfat_linux_tree/.config"

    case "$appendfat_mode" in
        builtin)
            grep '^CONFIG_APPENDFAT_FS=y$' "$appendfat_linux_tree/.config"
            grep '^CONFIG_APPENDFAT_VFAT_FS=y$' "$appendfat_linux_tree/.config"
            grep '^CONFIG_APPENDFAT_MSDOS_FS=y$' "$appendfat_linux_tree/.config"
            ;;
        module)
            grep '^CONFIG_APPENDFAT_FS=m$' "$appendfat_linux_tree/.config"
            grep '^CONFIG_APPENDFAT_VFAT_FS=m$' "$appendfat_linux_tree/.config"
            grep '^CONFIG_APPENDFAT_MSDOS_FS=m$' "$appendfat_linux_tree/.config"
            grep '^CONFIG_MODULE_UNLOAD=y$' "$appendfat_linux_tree/.config"
            ;;
    esac

    make -C "$appendfat_linux_tree" -j2 bzImage
    if [ "$appendfat_mode" = module ]; then
        # Use the normal in-tree module target so Kbuild generates the kernel
        # symbol table before modpost validates appendfat's .ko files.
        make -C "$appendfat_linux_tree" -j2 modules
    fi
}

appendfat_make_initramfs()
{
    appendfat_root=$1
    appendfat_output=$2

    (
        cd "$appendfat_root"
        find . -print0 | cpio --null -ov --format=newc | gzip -9
    ) > "$appendfat_output"
}
