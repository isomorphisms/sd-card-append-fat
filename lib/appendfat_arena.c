#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include "appendfat_arena.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

enum {
    ARENA_IO_BYTES = 256 * 1024,
    POINTER_BYTES = 64,
    TEMP_ATTEMPTS = 1000
};

static void arena_zero_state(appendfat_arena *arena)
{
    memset(arena, 0, sizeof(*arena));
    arena->arena_fd = -1;
    arena->lock_fd = -1;
}

static char *with_suffix(const char *path, const char *suffix)
{
    size_t a;
    size_t b;
    char *result;

    if (path == NULL || suffix == NULL) {
        errno = EINVAL;
        return NULL;
    }
    a = strlen(path);
    b = strlen(suffix);
    if (a > SIZE_MAX - b - 1U) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    result = malloc(a + b + 1U);
    if (result == NULL)
        return NULL;
    memcpy(result, path, a);
    memcpy(result + a, suffix, b + 1U);
    return result;
}

static int sync_fd(int fd)
{
    int result;
    do {
        result = fsync(fd);
    } while (result < 0 && errno == EINTR);
    return result;
}

static int write_all_at(int fd, const unsigned char *bytes, size_t length,
                        uint64_t offset)
{
    size_t written = 0;

    while (written < length) {
        uint64_t position = offset + (uint64_t)written;
        ssize_t count;

        if (position > (uint64_t)INT64_MAX) {
            errno = EOVERFLOW;
            return -1;
        }
        do {
            count = pwrite(fd, bytes + written, length - written,
                           (off_t)position);
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

static int read_exact_at(int fd, unsigned char *bytes, size_t length,
                         uint64_t offset)
{
    size_t consumed = 0;

    while (consumed < length) {
        uint64_t position = offset + (uint64_t)consumed;
        ssize_t count;

        if (position > (uint64_t)INT64_MAX) {
            errno = EOVERFLOW;
            return -1;
        }
        do {
            count = pread(fd, bytes + consumed, length - consumed,
                          (off_t)position);
        } while (count < 0 && errno == EINTR);
        if (count <= 0) {
            if (count == 0)
                errno = EIO;
            return -1;
        }
        consumed += (size_t)count;
    }
    return 0;
}

static int sync_parent(const char *path)
{
    char *copy;
    char *slash;
    const char *directory;
    int fd;
    int result;
    int saved_errno;

    copy = strdup(path);
    if (copy == NULL)
        return -1;
    slash = strrchr(copy, '/');
    if (slash == NULL) {
        directory = ".";
    } else if (slash == copy) {
        slash[1] = '\0';
        directory = copy;
    } else {
        *slash = '\0';
        directory = copy;
    }

    fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) {
        saved_errno = errno;
        free(copy);
        errno = saved_errno;
        return -1;
    }
    result = sync_fd(fd);
    saved_errno = errno;
    close(fd);
    free(copy);
    errno = saved_errno;
    return result;
}

static int read_used(const char *path, uint64_t *used_out)
{
    char buffer[POINTER_BYTES];
    char *end = NULL;
    uintmax_t value;
    ssize_t count;
    int fd;

    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        return -1;
    do {
        count = read(fd, buffer, sizeof(buffer) - 1U);
    } while (count < 0 && errno == EINTR);
    if (count < 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }
    close(fd);

    if (count <= 0 || (size_t)count >= sizeof(buffer) - 1U) {
        errno = EINVAL;
        return -1;
    }
    buffer[count] = '\0';
    errno = 0;
    value = strtoumax(buffer, &end, 10);
    if (errno != 0 || end == buffer || value > UINT64_MAX) {
        errno = EINVAL;
        return -1;
    }
    if (*end == '\n')
        ++end;
    if (*end != '\0') {
        errno = EINVAL;
        return -1;
    }
    *used_out = (uint64_t)value;
    return 0;
}

static char *temporary_pointer_path(const char *used_path, unsigned attempt)
{
    int needed;
    char *path;

    needed = snprintf(NULL, 0, "%s.tmp.%ld.%u",
                      used_path, (long)getpid(), attempt);
    if (needed < 0)
        return NULL;
    path = malloc((size_t)needed + 1U);
    if (path == NULL)
        return NULL;
    snprintf(path, (size_t)needed + 1U, "%s.tmp.%ld.%u",
             used_path, (long)getpid(), attempt);
    return path;
}

static int write_used_atomic(const char *used_path, uint64_t used)
{
    char content[POINTER_BYTES];
    int content_length;
    unsigned attempt;
    char *temporary = NULL;
    int fd = -1;
    int result = -1;

    content_length = snprintf(content, sizeof(content), "%" PRIu64 "\n", used);
    if (content_length < 0 || (size_t)content_length >= sizeof(content)) {
        errno = EOVERFLOW;
        return -1;
    }

    for (attempt = 0; attempt < TEMP_ATTEMPTS; ++attempt) {
        temporary = temporary_pointer_path(used_path, attempt);
        if (temporary == NULL)
            goto done;
        fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd >= 0)
            break;
        if (errno != EEXIST)
            goto done;
        free(temporary);
        temporary = NULL;
    }
    if (fd < 0) {
        errno = EEXIST;
        goto done;
    }

    {
        size_t written = 0;
        while (written < (size_t)content_length) {
            ssize_t count;
            do {
                count = write(fd, content + written,
                              (size_t)content_length - written);
            } while (count < 0 && errno == EINTR);
            if (count <= 0) {
                if (count == 0)
                    errno = EIO;
                goto done;
            }
            written += (size_t)count;
        }
    }

    if (sync_fd(fd) != 0)
        goto done;
    if (close(fd) != 0) {
        fd = -1;
        goto done;
    }
    fd = -1;

    if (rename(temporary, used_path) != 0)
        goto done;
    free(temporary);
    temporary = NULL;

    if (sync_parent(used_path) != 0)
        return -1;
    result = 0;

done:
    if (fd >= 0)
        close(fd);
    if (temporary != NULL) {
        unlink(temporary);
        free(temporary);
    }
    return result;
}

int appendfat_arena_reserve_fd(int fd, uint64_t current_capacity,
                               uint64_t required, uint64_t quantum,
                               uint64_t *new_capacity_out)
{
    unsigned char *zeroes;
    uint64_t target;
    uint64_t position;

    if (fd < 0 || quantum == 0 ||
        current_capacity > (uint64_t)INT64_MAX ||
        required > (uint64_t)INT64_MAX) {
        errno = EINVAL;
        return -1;
    }
    if (required <= current_capacity) {
        if (new_capacity_out != NULL)
            *new_capacity_out = current_capacity;
        return 0;
    }
    if (required > UINT64_MAX - (quantum - 1U)) {
        errno = EOVERFLOW;
        return -1;
    }
    target = ((required + quantum - 1U) ÷ quantum) * quantum;
    if (target > (uint64_t)INT64_MAX) {
        errno = EOVERFLOW;
        return -1;
    }

    zeroes = calloc(1U, ARENA_IO_BYTES);
    if (zeroes == NULL)
        return -1;
    position = current_capacity;
    while (position < target) {
        uint64_t remaining = target - position;
        size_t amount = remaining > ARENA_IO_BYTES
                      ? ARENA_IO_BYTES
                      : (size_t)remaining;
        if (write_all_at(fd, zeroes, amount, position) != 0) {
            int saved_errno = errno;
            free(zeroes);
            errno = saved_errno;
            return -1;
        }
        position += amount;
    }
    free(zeroes);
    if (new_capacity_out != NULL)
        *new_capacity_out = target;
    return 0;
}

int appendfat_arena_create(const char *path, uint64_t capacity)
{
    char *used_path = NULL;
    char *lock_path = NULL;
    int arena_fd = -1;
    int used_fd = -1;
    int lock_fd = -1;
    int result = -1;
    int arena_created = 0;
    int used_created = 0;
    int lock_created = 0;
    uint64_t grown = 0;

    if (path == NULL || capacity == 0 ||
        capacity > (uint64_t)INT64_MAX) {
        errno = EINVAL;
        return -1;
    }

    used_path = with_suffix(path, ".used");
    lock_path = with_suffix(path, ".lock");
    if (used_path == NULL || lock_path == NULL)
        goto done;

    lock_fd = open(lock_path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (lock_fd < 0)
        goto done;
    lock_created = 1;

    arena_fd = open(path, O_RDWR | O_CREAT | O_EXCL |
                    O_CLOEXEC | O_NOFOLLOW, 0600);
    if (arena_fd < 0)
        goto done;
    arena_created = 1;

    if (appendfat_arena_reserve_fd(arena_fd, 0, capacity,
                                   capacity, &grown) != 0 ||
        grown != capacity)
        goto done;
    if (sync_fd(arena_fd) != 0)
        goto done;

    used_fd = open(used_path, O_WRONLY | O_CREAT | O_EXCL |
                   O_CLOEXEC | O_NOFOLLOW, 0600);
    if (used_fd < 0)
        goto done;
    used_created = 1;
    if (write(used_fd, "0\n", 2U) != 2)
        goto done;
    if (sync_fd(used_fd) != 0 || sync_fd(lock_fd) != 0)
        goto done;
    if (sync_parent(path) != 0)
        goto done;

    result = 0;

done:
    if (arena_fd >= 0)
        close(arena_fd);
    if (used_fd >= 0)
        close(used_fd);
    if (lock_fd >= 0)
        close(lock_fd);
    if (result != 0) {
        if (used_created)
            unlink(used_path);
        if (arena_created)
            unlink(path);
        if (lock_created)
            unlink(lock_path);
    }
    free(used_path);
    free(lock_path);
    return result;
}

int appendfat_arena_open(appendfat_arena *arena, const char *path, int exclusive)
{
    struct stat status;
    uint64_t used;
    int operation;

    if (arena == NULL || path == NULL) {
        errno = EINVAL;
        return -1;
    }
    arena_zero_state(arena);
    arena->arena_path = strdup(path);
    arena->used_path = with_suffix(path, ".used");
    arena->lock_path = with_suffix(path, ".lock");
    if (arena->arena_path == NULL || arena->used_path == NULL ||
        arena->lock_path == NULL)
        goto fail;

    arena->lock_fd = open(arena->lock_path,
                          O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (arena->lock_fd < 0)
        goto fail;
    operation = exclusive ? LOCK_EX : LOCK_SH;
    while (flock(arena->lock_fd, operation) != 0) {
        if (errno == EINTR)
            continue;
        goto fail;
    }

    arena->arena_fd = open(path,
                           (exclusive ? O_RDWR : O_RDONLY) |
                           O_CLOEXEC | O_NOFOLLOW);
    if (arena->arena_fd < 0)
        goto fail;
    if (read_used(arena->used_path, &used) != 0)
        goto fail;
    if (fstat(arena->arena_fd, &status) != 0)
        goto fail;
    if (!S_ISREG(status.st_mode) || status.st_size < 0 ||
        used > (uint64_t)status.st_size) {
        errno = EINVAL;
        goto fail;
    }

    arena->capacity = (uint64_t)status.st_size;
    arena->committed = used;
    arena->cursor = used;
    return 0;

fail:
    appendfat_arena_close(arena);
    return -1;
}

void appendfat_arena_close(appendfat_arena *arena)
{
    if (arena == NULL)
        return;
    if (arena->arena_fd >= 0)
        close(arena->arena_fd);
    if (arena->lock_fd >= 0)
        close(arena->lock_fd);
    free(arena->arena_path);
    free(arena->used_path);
    free(arena->lock_path);
    arena_zero_state(arena);
}

int appendfat_arena_append(appendfat_arena *arena,
                           const void *bytes, size_t length)
{
    if (arena == NULL || arena->arena_fd < 0 ||
        (length != 0 && bytes == NULL)) {
        errno = EINVAL;
        return -1;
    }
    if (arena->cursor > arena->capacity ||
        (uint64_t)length > arena->capacity - arena->cursor) {
        errno = ENOSPC;
        return -1;
    }
    if (length != 0 &&
        write_all_at(arena->arena_fd, bytes, length, arena->cursor) != 0)
        return -1;
    arena->cursor += (uint64_t)length;
    return 0;
}

int appendfat_arena_commit(appendfat_arena *arena)
{
    if (arena == NULL || arena->arena_fd < 0 ||
        arena->used_path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (arena->cursor == arena->committed)
        return 0;
    if (sync_fd(arena->arena_fd) != 0)
        return -1;
    if (write_used_atomic(arena->used_path, arena->cursor) != 0)
        return -1;
    arena->committed = arena->cursor;
    return 0;
}

void appendfat_arena_discard_uncommitted(appendfat_arena *arena)
{
    if (arena != NULL)
        arena->cursor = arena->committed;
}

int appendfat_arena_read(const appendfat_arena *arena, uint64_t offset,
                         void *bytes, size_t capacity, size_t *length_out)
{
    uint64_t available;
    size_t amount;

    if (arena == NULL || arena->arena_fd < 0 || length_out == NULL ||
        (capacity != 0 && bytes == NULL) || offset > arena->committed) {
        errno = EINVAL;
        return -1;
    }
    available = arena->committed - offset;
    amount = available > (uint64_t)capacity
           ? capacity
           : (size_t)available;
    if (amount != 0 &&
        read_exact_at(arena->arena_fd, bytes, amount, offset) != 0)
        return -1;
    *length_out = amount;
    return 0;
}

uint64_t appendfat_arena_capacity(const appendfat_arena *arena)
{
    return arena != NULL ? arena->capacity : 0;
}

uint64_t appendfat_arena_committed(const appendfat_arena *arena)
{
    return arena != NULL ? arena->committed : 0;
}

uint64_t appendfat_arena_cursor(const appendfat_arena *arena)
{
    return arena != NULL ? arena->cursor : 0;
}
