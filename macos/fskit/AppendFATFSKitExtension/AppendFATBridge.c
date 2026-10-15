#if defined(APPENDFAT_FSKIT_SDK_PROBE)
/*
 * UNSIGNED SDK COMPILATION PROBE ONLY.
 * No arena or storage writes are possible in this configuration.
 * Shipping this configuration would be wrong: every I/O fails ENOTSUP.
 */
#include "AppendFATBridge.h"
#include <errno.h>

int appendfat_fskit_status(const char *path, uint64_t *committed,
                           uint64_t *capacity)
{
    (void)path; (void)committed; (void)capacity;
    return ENOTSUP;
}
int appendfat_fskit_read(const char *path, uint64_t offset, void *data,
                         size_t capacity, size_t *read_out)
{
    (void)path; (void)offset; (void)data; (void)capacity; (void)read_out;
    return ENOTSUP;
}
int appendfat_fskit_append(const char *path, uint64_t offset,
                           const void *data, size_t length,
                           uint64_t *new_committed)
{
    (void)path; (void)offset; (void)data; (void)length; (void)new_committed;
    return ENOTSUP;
}
#else
#include "AppendFATBridge.h"
#include "../../../lib/appendfat_arena.h"

#include <errno.h>
#include <stdint.h>

int appendfat_fskit_status(const char *path, uint64_t *committed,
                           uint64_t *capacity)
{
    appendfat_arena arena;
    int result;
    if (path == NULL || committed == NULL || capacity == NULL)
        return EINVAL;
    if (appendfat_arena_open(&arena, path, 0) != 0)
        return errno != 0 ? errno : EIO;
    *committed = appendfat_arena_committed(&arena);
    *capacity = appendfat_arena_capacity(&arena);
    appendfat_arena_close(&arena);
    result = 0;
    return result;
}

int appendfat_fskit_read(const char *path, uint64_t offset, void *data,
                         size_t capacity, size_t *read_out)
{
    appendfat_arena arena;
    int result = 0;
    uint64_t committed;
    if (path == NULL || read_out == NULL || (capacity > 0 && data == NULL))
        return EINVAL;
    *read_out = 0;
    if (appendfat_arena_open(&arena, path, 0) != 0)
        return errno != 0 ? errno : EIO;
    committed = appendfat_arena_committed(&arena);
    if (offset < committed &&
        appendfat_arena_read(&arena, offset, data, capacity, read_out) != 0)
        result = errno != 0 ? errno : EIO;
    appendfat_arena_close(&arena);
    return result;
}

int appendfat_fskit_append(const char *path, uint64_t offset,
                           const void *data, size_t length,
                           uint64_t *new_committed)
{
    appendfat_arena arena;
    int result = 0;
    if (path == NULL || new_committed == NULL ||
        (length > 0 && data == NULL))
        return EINVAL;
    if (appendfat_arena_open(&arena, path, 1) != 0)
        return errno != 0 ? errno : EIO;

    if (offset != appendfat_arena_committed(&arena)) {
        result = ESPIPE;
        goto done;
    }
    if (appendfat_arena_append(&arena, data, length) != 0) {
        result = errno != 0 ? errno : EIO;
        goto done;
    }
    if (appendfat_arena_commit(&arena) != 0) {
        result = errno != 0 ? errno : EIO;
        goto done;
    }
    *new_committed = appendfat_arena_committed(&arena);

done:
    if (result != 0)
        appendfat_arena_discard_uncommitted(&arena);
    appendfat_arena_close(&arena);
    return result;
}

#endif /* APPENDFAT_FSKIT_SDK_PROBE */
