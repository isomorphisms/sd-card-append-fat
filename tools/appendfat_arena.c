#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include "../lib/appendfat_arena.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { COPY_BUFFER_SIZE = 256 * 1024 };

static const char *program_name = "appendfat_arena";

static void usage(FILE *stream)
{
    fprintf(stream,
            "usage:\n"
            "  %s create ARENA CAPACITY_BYTES\n"
            "  %s append ARENA SOURCE|-\n"
            "  %s status ARENA\n"
            "  %s dump ARENA\n",
            program_name, program_name, program_name, program_name);
}

static void report_errno(const char *action, const char *path)
{
    fprintf(stderr, "%s: %s '%s': %s\n",
            program_name, action, path, strerror(errno));
}

static int parse_capacity(const char *text, uint64_t *capacity_out)
{
    char *end = NULL;
    uintmax_t value;

    errno = 0;
    value = strtoumax(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        value == 0 || value > (uintmax_t)INT64_MAX) {
        errno = EINVAL;
        return -1;
    }
    *capacity_out = (uint64_t)value;
    return 0;
}

static int command_create(const char *path, const char *capacity_text)
{
    uint64_t capacity;

    if (parse_capacity(capacity_text, &capacity) != 0) {
        fprintf(stderr, "%s: invalid capacity: %s\n",
                program_name, capacity_text);
        return -1;
    }
    if (appendfat_arena_create(path, capacity) != 0) {
        report_errno("cannot create arena", path);
        return -1;
    }
    printf("CREATED capacity_bytes=%" PRIu64 " arena=%s\n",
           capacity, path);
    return 0;
}

static int command_append(const char *path, const char *source_path)
{
    appendfat_arena arena;
    unsigned char *buffer = NULL;
    struct stat source_status;
    int source_fd = -1;
    int source_is_stdin = strcmp(source_path, "-") == 0;
    uint64_t old_used;
    int result = -1;

    if (appendfat_arena_open(&arena, path, 1) != 0) {
        report_errno("cannot open arena", path);
        return -1;
    }
    old_used = appendfat_arena_committed(&arena);

    if (source_is_stdin) {
        source_fd = STDIN_FILENO;
    } else {
        source_fd = open(source_path, O_RDONLY);
        if (source_fd < 0) {
            report_errno("cannot open source", source_path);
            goto done;
        }
        if (fstat(source_fd, &source_status) != 0 ||
            !S_ISREG(source_status.st_mode)) {
            if (errno == 0)
                errno = EINVAL;
            report_errno("invalid source", source_path);
            goto done;
        }
        if ((uint64_t)source_status.st_size >
            appendfat_arena_capacity(&arena) - old_used) {
            errno = ENOSPC;
            report_errno("source exceeds free arena capacity", source_path);
            goto done;
        }
    }

    buffer = malloc(COPY_BUFFER_SIZE);
    if (buffer == NULL)
        goto done;

    for (;;) {
        ssize_t count;
        do {
            count = read(source_fd, buffer, COPY_BUFFER_SIZE);
        } while (count < 0 && errno == EINTR);
        if (count < 0) {
            report_errno("cannot read source", source_path);
            goto done;
        }
        if (count == 0)
            break;
        if (appendfat_arena_append(&arena, buffer, (size_t)count) != 0) {
            report_errno("cannot append source", path);
            appendfat_arena_discard_uncommitted(&arena);
            goto done;
        }
    }

    if (appendfat_arena_commit(&arena) != 0) {
        report_errno("cannot commit arena", path);
        goto done;
    }

    printf("APPENDED old_used=%" PRIu64 " new_used=%" PRIu64
           " capacity_bytes=%" PRIu64 "\n",
           old_used, appendfat_arena_committed(&arena),
           appendfat_arena_capacity(&arena));
    result = 0;

done:
    if (!source_is_stdin && source_fd >= 0)
        close(source_fd);
    free(buffer);
    appendfat_arena_close(&arena);
    return result;
}

static int command_status(const char *path)
{
    appendfat_arena arena;

    if (appendfat_arena_open(&arena, path, 0) != 0) {
        report_errno("cannot inspect arena", path);
        return -1;
    }
    printf("capacity_bytes=%" PRIu64 " used_bytes=%" PRIu64
           " free_bytes=%" PRIu64 "\n",
           appendfat_arena_capacity(&arena),
           appendfat_arena_committed(&arena),
           appendfat_arena_capacity(&arena) -
           appendfat_arena_committed(&arena));
    appendfat_arena_close(&arena);
    return 0;
}

static int write_stdout(const unsigned char *bytes, size_t length)
{
    size_t written = 0;
    while (written < length) {
        ssize_t count;
        do {
            count = write(STDOUT_FILENO, bytes + written, length - written);
        } while (count < 0 && errno == EINTR);
        if (count <= 0) {
            if (count == 0)
                errno = EIO;
            return -1;
        }
        written += (size_t)count;
    }
    return 0;
}

static int command_dump(const char *path)
{
    appendfat_arena arena;
    unsigned char *buffer = NULL;
    uint64_t offset = 0;
    int result = -1;

    if (appendfat_arena_open(&arena, path, 0) != 0) {
        report_errno("cannot inspect arena", path);
        return -1;
    }
    buffer = malloc(COPY_BUFFER_SIZE);
    if (buffer == NULL)
        goto done;

    while (offset < appendfat_arena_committed(&arena)) {
        size_t count = 0;
        if (appendfat_arena_read(&arena, offset, buffer,
                                 COPY_BUFFER_SIZE, &count) != 0) {
            report_errno("cannot read arena", path);
            goto done;
        }
        if (count == 0 || write_stdout(buffer, count) != 0)
            goto done;
        offset += (uint64_t)count;
    }
    result = 0;

done:
    free(buffer);
    appendfat_arena_close(&arena);
    return result;
}

int main(int argc, char **argv)
{
    if (argc > 0 && argv[0] != NULL)
        program_name = argv[0];
    if (argc < 2) {
        usage(stderr);
        return 2;
    }
    if (strcmp(argv[1], "create") == 0) {
        if (argc != 4) { usage(stderr); return 2; }
        return command_create(argv[2], argv[3]) == 0 ? 0 : 1;
    }
    if (strcmp(argv[1], "append") == 0) {
        if (argc != 4) { usage(stderr); return 2; }
        return command_append(argv[2], argv[3]) == 0 ? 0 : 1;
    }
    if (strcmp(argv[1], "status") == 0) {
        if (argc != 3) { usage(stderr); return 2; }
        return command_status(argv[2]) == 0 ? 0 : 1;
    }
    if (strcmp(argv[1], "dump") == 0) {
        if (argc != 3) { usage(stderr); return 2; }
        return command_dump(argv[2]) == 0 ? 0 : 1;
    }
    usage(stderr);
    return 2;
}
