#include "../lib/appendfat_arena.h"
#include "../macos/fskit/AppendFATFSKitExtension/AppendFATBridge.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(test, label) do { if (!(test)) { fprintf(stderr, "FAIL: %s\n", label); return 1; } } while (0)

int main(int argc, char **argv) {
    const char hello[] = "hello";
    const char world[] = " world";
    char data[64] = {0};
    uint64_t used = 0, capacity = 0, end = 0;
    size_t count = 0;
    if (argc != 2) return 2;
    CHECK(appendfat_arena_create(argv[1], 64) == 0, "create scratch arena");
    CHECK(appendfat_fskit_status(argv[1], &used, &capacity) == 0 && used == 0 && capacity == 64, "initial state");
    CHECK(appendfat_fskit_append(argv[1], 0, hello, 5, &end) == 0 && end == 5, "append hello");
    CHECK(appendfat_fskit_append(argv[1], 5, world, 6, &end) == 0 && end == 11, "append world");
    CHECK(appendfat_fskit_append(argv[1], 0, world, 6, &end) == ESPIPE, "forbid overwrite/stale offset");
    CHECK(appendfat_fskit_read(argv[1], 0, data, 11, &count) == 0 && count == 11 &&
          memcmp(data, "hello world", 11) == 0, "committed prefix reopens");
    CHECK(appendfat_fskit_read(argv[1], 5, data, 6, &count) == 0 && count == 6 &&
          memcmp(data, " world", 6) == 0, "read from offset");
    CHECK(appendfat_fskit_read(argv[1], 1000, data, 6, &count) == 0 && count == 0, "EOF");
    CHECK(appendfat_fskit_append(argv[1], 11, data, 60, &end) == ENOSPC, "overflow");
    CHECK(appendfat_fskit_status(argv[1], &used, &capacity) == 0 && used == 11 && capacity == 64, "failed append did not commit");
    CHECK(appendfat_fskit_append(argv[1], 11, NULL, 0, &end) == 0 && end == 11, "empty append");
    puts("PASS: FSKit bridge append/reopen/overflow");
    return 0;
}
