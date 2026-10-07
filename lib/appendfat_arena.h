#ifndef APPENDFAT_ARENA_H
#define APPENDFAT_ARENA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct appendfat_arena {
    int arena_fd;
    int lock_fd;
    uint64_t capacity;
    uint64_t committed;
    uint64_t cursor;
    char *arena_path;
    char *used_path;
    char *lock_path;
} appendfat_arena;

int appendfat_arena_create(const char *path, uint64_t capacity);
int appendfat_arena_open(appendfat_arena *arena, const char *path, int exclusive);
void appendfat_arena_close(appendfat_arena *arena);

int appendfat_arena_append(appendfat_arena *arena, const void *bytes, size_t length);
int appendfat_arena_commit(appendfat_arena *arena);
void appendfat_arena_discard_uncommitted(appendfat_arena *arena);

int appendfat_arena_read(const appendfat_arena *arena, uint64_t offset,
                         void *bytes, size_t capacity, size_t *length_out);

uint64_t appendfat_arena_capacity(const appendfat_arena *arena);
uint64_t appendfat_arena_committed(const appendfat_arena *arena);
uint64_t appendfat_arena_cursor(const appendfat_arena *arena);

/*
 * Grow an already-open regular file to the next quantum by explicitly
 * zero-filling the newly reserved region. No durability barrier is issued.
 * Consumers that already own their durability protocol can use this primitive
 * without adopting the sidecar .used protocol.
 */
int appendfat_arena_reserve_fd(int fd, uint64_t current_capacity,
                               uint64_t required, uint64_t quantum,
                               uint64_t *new_capacity_out);

#ifdef __cplusplus
}
#endif

#endif
