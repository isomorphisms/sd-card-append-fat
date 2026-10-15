#ifndef APPENDFAT_FSKIT_BRIDGE_H
#define APPENDFAT_FSKIT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

/* Returns a POSIX errno value; 0 means success. Owns no persistent handles. */
int appendfat_fskit_status(const char *path, uint64_t *committed,
                           uint64_t *capacity);
int appendfat_fskit_read(const char *path, uint64_t offset, void *data,
                         size_t capacity, size_t *read_out);
/* Only writes exactly at the current committed end. Commits before returning. */
int appendfat_fskit_append(const char *path, uint64_t offset,
                           const void *data, size_t length,
                           uint64_t *new_committed);
#endif
