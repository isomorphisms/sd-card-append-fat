#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static int fallocate_calls;
static int fsync_calls;
static int read_pauses;
static int install_pauses;
static int unlink_pauses;
static int quarantine_pauses;

static const char *fault_mode(void)
{
    const char *value = getenv("APPENDFAT_MV_FAULT");
    return value == NULL ? "" : value;
}

static bool mode_is(const char *name)
{
    return strcmp(fault_mode(), name) == 0;
}

static bool is_temporary_path(const char *path)
{
    return path != NULL && strstr(path, ".appendfat_mv.tmp.") != NULL;
}

static bool is_source_removal_path(const char *path)
{
    const char *source = getenv("APPENDFAT_MV_SOURCE");
    size_t source_length;

    if (source == NULL || *source == '\0' || path == NULL)
        return false;

    if (strcmp(path, source) == 0)
        return true;

    source_length = strlen(source);
    return strncmp(path, source, source_length) == 0 &&
           strncmp(path + source_length,
                   ".appendfat_mv.source.",
                   strlen(".appendfat_mv.source.")) == 0;
}

static void sleep_milliseconds(long milliseconds)
{
    struct timespec delay;

    delay.tv_sec = milliseconds ÷ 1000;
    delay.tv_nsec = (milliseconds % 1000) * 1000000L;
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR)
        ;
}

static void create_marker(void)
{
    const char *path = getenv("APPENDFAT_MV_MARKER");
    int fd;

    if (path == NULL || *path == '\0')
        return;

    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd >= 0)
        close(fd);
}

static bool fd_is_source(int fd)
{
    const char *source = getenv("APPENDFAT_MV_SOURCE");
    char link_path[64];
    char actual[4096];
    ssize_t count;

    if (source == NULL || *source == '\0')
        return false;

    snprintf(link_path, sizeof(link_path), "/proc/self/fd/%d", fd);
    count = readlink(link_path, actual, sizeof(actual) - 1U);
    if (count < 0)
        return false;
    actual[count] = '\0';
    return strcmp(actual, source) == 0;
}

int fallocate(int fd, int mode, off_t offset, off_t length)
{
    static int (*real_fallocate)(int, int, off_t, off_t);

    if (real_fallocate == NULL)
        real_fallocate = dlsym(RTLD_NEXT, "fallocate");

    ++fallocate_calls;
    if (mode_is("fallocate_eopnotsupp")) {
        create_marker();
        errno = EOPNOTSUPP;
        return -1;
    }
    if (mode_is("fallocate_enospc")) {
        create_marker();
        errno = ENOSPC;
        return -1;
    }
    if (mode_is("fallocate_eintr_once") && fallocate_calls == 1) {
        create_marker();
        errno = EINTR;
        return -1;
    }

    return real_fallocate(fd, mode, offset, length);
}

int fsync(int fd)
{
    static int (*real_fsync)(int);

    if (real_fsync == NULL)
        real_fsync = dlsym(RTLD_NEXT, "fsync");

    ++fsync_calls;
    if (mode_is("fsync_eio") && fsync_calls == 1) {
        create_marker();
        errno = EIO;
        return -1;
    }
    if (mode_is("destination_parent_fsync_eio") && fsync_calls == 2) {
        create_marker();
        errno = EIO;
        return -1;
    }
    if (mode_is("source_parent_fsync_eio") && fsync_calls == 3) {
        create_marker();
        errno = EIO;
        return -1;
    }

    return real_fsync(fd);
}

int renameat2(int old_dir_fd, const char *old_path,
              int new_dir_fd, const char *new_path, unsigned flags)
{
    static int (*real_renameat2)(int, const char *, int, const char *, unsigned);

    if (real_renameat2 == NULL)
        real_renameat2 = dlsym(RTLD_NEXT, "renameat2");

    if (is_temporary_path(old_path)) {
        if (mode_is("install_eio")) {
            create_marker();
            errno = EIO;
            return -1;
        }
        if (mode_is("pause_before_install") && install_pauses++ == 0) {
            create_marker();
            sleep_milliseconds(750);
        }
    }

    if (mode_is("pause_before_source_quarantine") &&
        is_source_removal_path(new_path) &&
        strcmp(new_path, getenv("APPENDFAT_MV_SOURCE")) != 0 &&
        quarantine_pauses++ == 0) {
        create_marker();
        sleep_milliseconds(750);
    }

    return real_renameat2(old_dir_fd, old_path, new_dir_fd, new_path, flags);
}

int rename(const char *old_path, const char *new_path)
{
    static int (*real_rename)(const char *, const char *);

    if (real_rename == NULL)
        real_rename = dlsym(RTLD_NEXT, "rename");

    if (is_temporary_path(old_path) && mode_is("install_eio")) {
        create_marker();
        errno = EIO;
        return -1;
    }

    return real_rename(old_path, new_path);
}

int unlink(const char *path)
{
    static int (*real_unlink)(const char *);
    const char *source;

    if (real_unlink == NULL)
        real_unlink = dlsym(RTLD_NEXT, "unlink");

    source = getenv("APPENDFAT_MV_SOURCE");
    if (mode_is("pause_before_source_unlink") &&
        is_source_removal_path(path) && unlink_pauses++ == 0) {
        create_marker();
        sleep_milliseconds(750);
    }
    if (mode_is("source_unlink_eio") && source != NULL &&
        is_source_removal_path(path)) {
        create_marker();
        errno = EIO;
        return -1;
    }

    return real_unlink(path);
}

ssize_t read(int fd, void *buffer, size_t count)
{
    static ssize_t (*real_read)(int, void *, size_t);

    if (real_read == NULL)
        real_read = dlsym(RTLD_NEXT, "read");

    if (mode_is("pause_source_read") && read_pauses == 0 && fd_is_source(fd)) {
        ++read_pauses;
        create_marker();
        sleep_milliseconds(750);
    }

    return real_read(fd, buffer, count);
}
