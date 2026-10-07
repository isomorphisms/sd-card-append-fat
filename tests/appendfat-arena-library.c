#include "../lib/appendfat_arena.h"

#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    appendfat_arena arena;
    unsigned char bytes[16];
    size_t count;
    int fd;
    uint64_t capacity;

    assert(argc == 2);
    assert(appendfat_arena_create(argv[1], 4096) == 0);

    assert(appendfat_arena_open(&arena, argv[1], 1) == 0);
    assert(appendfat_arena_append(&arena, "alpha", 5) == 0);
    assert(appendfat_arena_cursor(&arena) == 5);
    assert(appendfat_arena_committed(&arena) == 0);
    appendfat_arena_close(&arena);

    /* Uncommitted bytes do not advance the durable pointer. */
    assert(appendfat_arena_open(&arena, argv[1], 1) == 0);
    assert(appendfat_arena_cursor(&arena) == 0);
    assert(appendfat_arena_append(&arena, "beta", 4) == 0);
    assert(appendfat_arena_commit(&arena) == 0);
    assert(appendfat_arena_committed(&arena) == 4);

    memset(bytes, 0, sizeof(bytes));
    assert(appendfat_arena_read(&arena, 0, bytes,
                                sizeof(bytes), &count) == 0);
    assert(count == 4);
    assert(memcmp(bytes, "beta", 4) == 0);
    appendfat_arena_close(&arena);

    /* Consumers with their own journal can use only reserve-ahead. */
    fd = open(argv[1], O_RDWR);
    assert(fd >= 0);
    assert(appendfat_arena_reserve_fd(fd, 4096, 4097, 4096,
                                      &capacity) == 0);
    assert(capacity == 8192);
    close(fd);

    puts("appendfat_arena library tests: PASS");
    return 0;
}
