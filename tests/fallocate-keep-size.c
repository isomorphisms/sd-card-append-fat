// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <unistd.h>

static unsigned long long parse_number(const char *text)
{
    char *end = NULL;
    unsigned long long value;

    errno = 0;
    value = strtoull(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0') {
        fprintf(stderr, "invalid number: %s\n", text);
        exit(2);
    }
    return value;
}

static long long parse_signed_number(const char *text)
{
    char *end = NULL;
    long long value;

    errno = 0;
    value = strtoll(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0') {
        fprintf(stderr, "invalid signed number: %s\n", text);
        exit(2);
    }
    return value;
}

static int open_create(const char *path)
{
    int fd = open(path, O_CREAT | O_RDWR, 0666);

    if (fd < 0) {
        perror(path);
        exit(1);
    }
    return fd;
}

static int open_existing(const char *path, int flags)
{
    int fd = open(path, flags);

    if (fd < 0) {
        perror(path);
        exit(1);
    }
    return fd;
}

static void require_size(int fd, unsigned long long expected)
{
    struct stat st;

    if (fstat(fd, &st) != 0) {
        perror("fstat");
        exit(1);
    }
    if ((unsigned long long)st.st_size != expected) {
        fprintf(stderr, "size mismatch: expected=%llu actual=%" PRIuMAX "\n",
                expected, (uintmax_t)st.st_size);
        exit(1);
    }
    printf("size=%" PRIuMAX " blocks=%" PRIuMAX "\n",
           (uintmax_t)st.st_size, (uintmax_t)st.st_blocks);
}

static void require_blocks(const char *path, unsigned long long expected)
{
    struct stat st;
    int fd = open_existing(path, O_RDONLY);

    if (fstat(fd, &st) != 0) {
        perror("fstat blocks");
        exit(1);
    }
    if (close(fd) != 0) {
        perror("close blocks");
        exit(1);
    }

    if ((unsigned long long)st.st_blocks != expected) {
        fprintf(stderr,
                "block-count mismatch for %s: expected=%llu actual=%" PRIuMAX "\n",
                path, expected, (uintmax_t)st.st_blocks);
        exit(1);
    }

    printf("blocks path=%s size=%" PRIuMAX " blocks=%" PRIuMAX "\n",
           path, (uintmax_t)st.st_size, (uintmax_t)st.st_blocks);
}

static void read_vda_write_stats(unsigned long long *writes,
				 unsigned long long *sectors)
{
	unsigned long long reads, read_merges, read_sectors, read_ms;
	unsigned long long write_merges, write_ms;
	FILE *stream = fopen("/sys/block/vda/stat", "r");

	if (stream == NULL) {
		perror("open /sys/block/vda/stat");
		exit(1);
	}
	if (fscanf(stream, "%llu %llu %llu %llu %llu %llu %llu %llu",
		   &reads, &read_merges, &read_sectors, &read_ms,
		   writes, &write_merges, sectors, &write_ms) != 8) {
		fprintf(stderr, "cannot parse /sys/block/vda/stat\n");
		exit(1);
	}
	if (fclose(stream) != 0) {
		perror("close /sys/block/vda/stat");
		exit(1);
	}
}

static void reserve_keep_size(const char *path,
                              unsigned long long offset,
                              unsigned long long length)
{
    struct stat before;
    struct stat after;
    int fd = open_create(path);

    if (fstat(fd, &before) != 0) {
        perror("fstat before reserve");
        exit(1);
    }
    if (fallocate(fd, FALLOC_FL_KEEP_SIZE,
                  (off_t)offset, (off_t)length) != 0) {
        perror("fallocate keep size");
        exit(1);
    }
    if (fstat(fd, &after) != 0) {
        perror("fstat after reserve");
        exit(1);
    }
    if (close(fd) != 0) {
        perror("close reserve");
        exit(1);
    }

    if (after.st_size != before.st_size) {
        fprintf(stderr,
                "keep-size reservation changed logical size: %" PRIuMAX
                " -> %" PRIuMAX "\n",
                (uintmax_t)before.st_size, (uintmax_t)after.st_size);
        exit(1);
    }

    printf("reserve path=%s size=%" PRIuMAX
           " blocks_before=%" PRIuMAX " blocks_after=%" PRIuMAX "\n",
           path,
           (uintmax_t)after.st_size,
           (uintmax_t)before.st_blocks,
           (uintmax_t)after.st_blocks);
}

static void reserve_cluster_count(const char *path,
				  unsigned long long current_clusters,
				  unsigned long long target_clusters)
{
	struct stat before;
	struct stat after;
	unsigned long long cluster_bytes;
	unsigned long long target_bytes;
	unsigned long long writes_before, writes_after;
	unsigned long long sectors_before, sectors_after;
	int fd = open_create(path);

	sync();
	read_vda_write_stats(&writes_before, &sectors_before);
	if (current_clusters == 0) {
		if (fallocate(fd, FALLOC_FL_KEEP_SIZE, 0, 1) != 0) {
			perror("fallocate initial cluster");
			exit(1);
		}
		current_clusters = 1;
	}
	if (fstat(fd, &before) != 0) {
		perror("fstat before cluster reservation");
		exit(1);
	}
	if (before.st_blocks <= 0 ||
	    (unsigned long long)before.st_blocks % current_clusters != 0) {
		fprintf(stderr, "cannot infer cluster size from allocation\n");
		exit(1);
	}
	cluster_bytes = (unsigned long long)before.st_blocks * 512 /
		current_clusters;
	if (cluster_bytes == 0 ||
	    target_clusters > (unsigned long long)INT64_MAX / cluster_bytes) {
		fprintf(stderr, "invalid cluster reservation size\n");
		exit(1);
	}
	target_bytes = cluster_bytes * target_clusters;
	if (fallocate(fd, FALLOC_FL_KEEP_SIZE, 0, (off_t)target_bytes) != 0) {
		perror("fallocate cluster reservation");
		exit(1);
	}
	if (fstat(fd, &after) != 0) {
		perror("fstat after cluster reservation");
		exit(1);
	}
	sync();
	read_vda_write_stats(&writes_after, &sectors_after);
	if (after.st_size != before.st_size ||
	    (unsigned long long)after.st_blocks != target_bytes / 512) {
		fprintf(stderr,
			"cluster reservation mismatch: size=%" PRIuMAX
			" blocks=%" PRIuMAX " expected_blocks=%llu\n",
			(uintmax_t)after.st_size, (uintmax_t)after.st_blocks,
			target_bytes / 512);
		exit(1);
	}
	if (close(fd) != 0) {
		perror("close cluster reservation");
		exit(1);
	}
	printf("reserve_clusters path=%s current=%llu target=%llu"
	       " cluster_bytes=%llu size=%" PRIuMAX " blocks=%" PRIuMAX
	       " vda_write_ops=%llu vda_write_sectors=%llu\n",
	       path, current_clusters, target_clusters, cluster_bytes,
	       (uintmax_t)after.st_size, (uintmax_t)after.st_blocks,
	       writes_after - writes_before, sectors_after - sectors_before);
}

static void append_bytes(const char *path,
                         unsigned long long count,
                         unsigned char value)
{
    unsigned char buffer[4096];
    unsigned long long left = count;
    struct stat after;
    int fd = open_existing(path, O_WRONLY | O_APPEND);

    memset(buffer, value, sizeof(buffer));

    while (left > 0) {
        size_t amount =
            left > (unsigned long long)sizeof(buffer)
                ? sizeof(buffer)
                : (size_t)left;
        ssize_t written = write(fd, buffer, amount);

        if (written < 0) {
            perror("write append");
            exit(1);
        }
        if (written == 0) {
            fprintf(stderr, "zero-length append write\n");
            exit(1);
        }
        left -= (unsigned long long)written;
    }

    if (fsync(fd) != 0) {
        perror("fsync append");
        exit(1);
    }
    if (fstat(fd, &after) != 0) {
        perror("fstat append");
        exit(1);
    }
    if (close(fd) != 0) {
        perror("close append");
        exit(1);
    }

    printf("append path=%s bytes=%llu size=%" PRIuMAX
           " blocks=%" PRIuMAX "\n",
           path, count,
           (uintmax_t)after.st_size,
           (uintmax_t)after.st_blocks);
}

static void write_bytes_fd(int fd,
                           unsigned long long count,
                           unsigned char value)
{
    unsigned char buffer[4096];
    unsigned long long left = count;

    memset(buffer, value, sizeof(buffer));
    while (left > 0) {
        size_t amount =
            left > (unsigned long long)sizeof(buffer)
                ? sizeof(buffer)
                : (size_t)left;
        ssize_t written = write(fd, buffer, amount);

        if (written < 0) {
            perror("write sequence");
            exit(1);
        }
        if (written == 0) {
            fprintf(stderr, "zero-length sequence write\n");
            exit(1);
        }
        left -= (unsigned long long)written;
    }
}

static unsigned long long fd_cluster_bytes(int fd)
{
    struct statvfs fs;
    unsigned long long cluster_bytes;

    if (fstatvfs(fd, &fs) != 0) {
        perror("fstatvfs");
        exit(1);
    }
    cluster_bytes = (unsigned long long)fs.f_bsize;
    if (cluster_bytes == 0 || cluster_bytes % 512 != 0) {
        fprintf(stderr, "invalid FAT cluster size: %llu\n", cluster_bytes);
        exit(1);
    }
    return cluster_bytes;
}

static void require_fd_state(int fd,
                             unsigned long long expected_size,
                             unsigned long long expected_clusters,
                             const char *label)
{
    struct stat st;
    unsigned long long cluster_bytes;
    unsigned long long blocks_per_cluster;
    unsigned long long expected_blocks;

    if (fstat(fd, &st) != 0) {
        perror("fstat sequence");
        exit(1);
    }
    cluster_bytes = fd_cluster_bytes(fd);
    blocks_per_cluster = cluster_bytes / 512;
    expected_blocks = expected_clusters * blocks_per_cluster;
    if ((unsigned long long)st.st_size != expected_size ||
        (unsigned long long)st.st_blocks != expected_blocks) {
        fprintf(stderr,
                "%s state mismatch: expected size=%llu clusters=%llu "
                "blocks=%llu actual size=%" PRIuMAX " blocks=%" PRIuMAX
                " cluster_bytes=%" PRIuMAX "\n",
                label, expected_size, expected_clusters, expected_blocks,
                (uintmax_t)st.st_size, (uintmax_t)st.st_blocks,
                (uintmax_t)cluster_bytes);
        exit(1);
    }

    printf("%s size=%" PRIuMAX " clusters=%llu blocks=%" PRIuMAX
           " cluster_bytes=%" PRIuMAX "\n",
           label, (uintmax_t)st.st_size, expected_clusters,
           (uintmax_t)st.st_blocks, (uintmax_t)cluster_bytes);
}

static void reserve_ahead_sequence(const char *path)
{
    unsigned long long cluster_bytes;
    unsigned long long first_batch_bytes;
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY | O_APPEND, 0666);

    if (fd < 0) {
        perror(path);
        exit(1);
    }
    cluster_bytes = fd_cluster_bytes(fd);
    if (cluster_bytes == 0 ||
        cluster_bytes > (unsigned long long)INT64_MAX / 4) {
        fprintf(stderr, "invalid reserve-ahead cluster geometry\n");
        exit(1);
    }
    first_batch_bytes = cluster_bytes * 4;

    write_bytes_fd(fd, 1, 65);
    require_fd_state(fd, 1, 4, "reserve_ahead_initial");

    write_bytes_fd(fd, first_batch_bytes - 1, 66);
    require_fd_state(fd, first_batch_bytes, 4, "reserve_ahead_consumed");

    write_bytes_fd(fd, 1, 67);
    require_fd_state(fd, first_batch_bytes + 1, 8, "reserve_ahead_refill");

    if (fsync(fd) != 0) {
        perror("fsync reserve-ahead sequence");
        exit(1);
    }
    if (close(fd) != 0) {
        perror("close reserve-ahead sequence");
        exit(1);
    }
}

static void reserve_ahead_truncate(const char *path)
{
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0666);

    if (fd < 0) {
        perror(path);
        exit(1);
    }

    write_bytes_fd(fd, 600, 84);
    require_fd_state(fd, 600, 4, "reserve_ahead_before_truncate");

    if (ftruncate(fd, 100) != 0) {
        perror("reserve-ahead ftruncate");
        exit(1);
    }
    require_fd_state(fd, 100, 1, "reserve_ahead_after_truncate");

    if (fsync(fd) != 0) {
        perror("fsync reserve-ahead truncate");
        exit(1);
    }
    if (close(fd) != 0) {
        perror("close reserve-ahead truncate");
        exit(1);
    }
}

static void reserve_ahead_unlink(const char *path)
{
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0666);

    if (fd < 0) {
        perror(path);
        exit(1);
    }

    write_bytes_fd(fd, 1, 85);
    require_fd_state(fd, 1, 4, "reserve_ahead_before_unlink");

    if (unlink(path) != 0) {
        perror("reserve-ahead unlink");
        exit(1);
    }
    if (close(fd) != 0) {
        perror("close reserve-ahead unlinked file");
        exit(1);
    }
}

static void reserve_ahead_near_full(const char *path)
{
    unsigned char byte = 69;
    struct stat st;
    unsigned long long cluster_bytes;
    unsigned long long two_cluster_bytes;
    ssize_t result;
    int saved_errno;
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR | O_APPEND, 0666);

    if (fd < 0) {
        perror(path);
        exit(1);
    }
    cluster_bytes = fd_cluster_bytes(fd);
    if (cluster_bytes == 0 ||
        cluster_bytes > (unsigned long long)INT64_MAX / 2) {
        fprintf(stderr, "invalid near-full cluster geometry\n");
        exit(1);
    }
    two_cluster_bytes = cluster_bytes * 2;

    write_bytes_fd(fd, 1, 65);
    require_fd_state(fd, 1, 1, "reserve_ahead_near_full_first");

    write_bytes_fd(fd, cluster_bytes - 1, 66);
    require_fd_state(fd, cluster_bytes, 1,
                     "reserve_ahead_near_full_first_full");

    write_bytes_fd(fd, 1, 67);
    require_fd_state(fd, cluster_bytes + 1, 2,
                     "reserve_ahead_near_full_second");

    write_bytes_fd(fd, cluster_bytes - 1, 68);
    require_fd_state(fd, two_cluster_bytes, 2,
                     "reserve_ahead_near_full_second_full");

    errno = 0;
    result = write(fd, &byte, 1);
    saved_errno = errno;
    if (result >= 0 || saved_errno != ENOSPC) {
        fprintf(stderr,
                "expected near-full append ENOSPC, result=%zd errno=%d (%s)\n",
                result, saved_errno, strerror(saved_errno));
        exit(1);
    }
    require_fd_state(fd, two_cluster_bytes, 2,
                     "reserve_ahead_near_full_enospc");

    if (fstat(fd, &st) != 0) {
        perror("fstat near-full result");
        exit(1);
    }
    if (fsync(fd) != 0) {
        perror("fsync near-full sequence");
        exit(1);
    }
    if (close(fd) != 0) {
        perror("close near-full sequence");
        exit(1);
    }

    printf("reserve_ahead_near_full_enospc size=%" PRIuMAX
           " blocks=%" PRIuMAX " cluster_bytes=%llu\n",
           (uintmax_t)st.st_size, (uintmax_t)st.st_blocks, cluster_bytes);
}

static void fill_leave_clusters(const char *path,
                                unsigned long long leave_clusters)
{
    unsigned char buffer[65536];
    unsigned long long cluster_bytes;
    unsigned long long leave_bytes;
    struct stat st;
    off_t target_size;
    int fd;

    fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0666);
    if (fd < 0) {
        perror(path);
        exit(1);
    }
    cluster_bytes = fd_cluster_bytes(fd);
    if (cluster_bytes == 0 ||
        leave_clusters > (unsigned long long)INT64_MAX / cluster_bytes) {
        fprintf(stderr, "invalid fill-leave geometry\n");
        exit(2);
    }
    leave_bytes = cluster_bytes * leave_clusters;
    memset(buffer, 0x5a, sizeof(buffer));

    for (;;) {
        ssize_t written = write(fd, buffer, sizeof(buffer));

        if (written > 0)
            continue;
        if (written < 0 && errno == ENOSPC)
            break;
        if (written < 0) {
            perror("fill write");
            exit(1);
        }
        fprintf(stderr, "zero-length fill write\n");
        exit(1);
    }

    if (fstat(fd, &st) != 0) {
        perror("fstat filled file");
        exit(1);
    }
    if ((unsigned long long)st.st_size < leave_bytes ||
        (unsigned long long)st.st_size % cluster_bytes != 0) {
        fprintf(stderr,
                "filled size is not compatible with requested cluster geometry: "
                "size=%" PRIuMAX " cluster_bytes=%llu leave_clusters=%llu\n",
                (uintmax_t)st.st_size, cluster_bytes, leave_clusters);
        exit(1);
    }

    target_size = st.st_size - (off_t)leave_bytes;
    if (ftruncate(fd, target_size) != 0) {
        perror("ftruncate filled file");
        exit(1);
    }
    if (fsync(fd) != 0) {
        perror("fsync filled file");
        exit(1);
    }
    if (close(fd) != 0) {
        perror("close filled file");
        exit(1);
    }

    printf("fill_leave path=%s full_size=%" PRIuMAX
           " final_size=%" PRIuMAX " leave_clusters=%llu cluster_bytes=%llu\n",
           path, (uintmax_t)st.st_size, (uintmax_t)target_size,
           leave_clusters, cluster_bytes);
}

static void require_minimal_allocation(const char *path)
{
    struct stat st;
    unsigned long long cluster_bytes;
    unsigned long long clusters;
    unsigned long long expected_blocks;
    int fd = open_existing(path, O_RDONLY);

    if (fstat(fd, &st) != 0) {
        perror("fstat minimal allocation");
        exit(1);
    }
    cluster_bytes = fd_cluster_bytes(fd);
    if (close(fd) != 0) {
        perror("close minimal allocation");
        exit(1);
    }

    if (cluster_bytes == 0 || cluster_bytes % 512 != 0) {
        fprintf(stderr, "invalid minimal-allocation cluster size\n");
        exit(1);
    }
    clusters = st.st_size == 0
        ? 0
        : ((unsigned long long)st.st_size + cluster_bytes - 1) / cluster_bytes;
    expected_blocks = clusters * (cluster_bytes / 512);

    if ((unsigned long long)st.st_blocks != expected_blocks) {
        fprintf(stderr,
                "nonminimal allocation for %s: size=%" PRIuMAX
                " blocks=%" PRIuMAX " expected_blocks=%llu"
                " cluster_bytes=%llu\n",
                path, (uintmax_t)st.st_size, (uintmax_t)st.st_blocks,
                expected_blocks, cluster_bytes);
        exit(1);
    }

    printf("minimal_allocation path=%s size=%" PRIuMAX
           " clusters=%llu blocks=%" PRIuMAX " cluster_bytes=%llu\n",
           path, (uintmax_t)st.st_size, clusters,
           (uintmax_t)st.st_blocks, cluster_bytes);
}

static void append_measure_workload(const char *path,
                                    unsigned long long target_clusters,
                                    unsigned long long chunk_bytes,
                                    unsigned char value)
{
    unsigned char buffer[4096];
    struct stat st;
    unsigned long long cluster_bytes;
    unsigned long long target_bytes;
    unsigned long long left;
    unsigned long long writes_before, writes_after;
    unsigned long long sectors_before, sectors_after;
    int fd;

    if (target_clusters == 0 || chunk_bytes == 0 ||
        chunk_bytes > sizeof(buffer)) {
        fprintf(stderr, "invalid append measurement workload\n");
        exit(2);
    }

    fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0666);
    if (fd < 0) {
        perror(path);
        exit(1);
    }
    cluster_bytes = fd_cluster_bytes(fd);
    if (cluster_bytes == 0 ||
        target_clusters > (unsigned long long)INT64_MAX / cluster_bytes) {
        fprintf(stderr, "invalid append measurement geometry\n");
        exit(2);
    }
    target_bytes = target_clusters * cluster_bytes;
    left = target_bytes;
    memset(buffer, value, sizeof(buffer));

    sync();
    read_vda_write_stats(&writes_before, &sectors_before);
    printf("APPENDFAT_APPEND_MEASURE_BEGIN clusters=%llu cluster_bytes=%llu "
           "chunk_bytes=%llu target_bytes=%llu\n",
           target_clusters, cluster_bytes, chunk_bytes, target_bytes);
    fflush(stdout);

    while (left > 0) {
        size_t amount = left < chunk_bytes ? (size_t)left : (size_t)chunk_bytes;
        ssize_t written = write(fd, buffer, amount);

        if (written < 0) {
            perror("append measurement write");
            exit(1);
        }
        if (written == 0) {
            fprintf(stderr, "zero-length append measurement write\n");
            exit(1);
        }
        left -= (unsigned long long)written;
    }

    if (fsync(fd) != 0) {
        perror("fsync append measurement");
        exit(1);
    }
    sync();
    read_vda_write_stats(&writes_after, &sectors_after);
    if (fstat(fd, &st) != 0) {
        perror("fstat append measurement result");
        exit(1);
    }
    if ((unsigned long long)st.st_size != target_bytes) {
        fprintf(stderr,
                "append measurement size mismatch: expected=%llu actual=%" PRIuMAX "\n",
                target_bytes, (uintmax_t)st.st_size);
        exit(1);
    }

    printf("APPENDFAT_APPEND_WORKLOAD size=%" PRIuMAX
           " blocks=%" PRIuMAX " cluster_bytes=%llu"
           " vda_write_ops=%llu vda_write_sectors=%llu\n",
           (uintmax_t)st.st_size, (uintmax_t)st.st_blocks, cluster_bytes,
           writes_after - writes_before, sectors_after - sectors_before);
    printf("APPENDFAT_APPEND_MEASURE_END\n");
    fflush(stdout);

    if (close(fd) != 0) {
        perror("close append measurement");
        exit(1);
    }
}

static void check_file(const char *path,
                       unsigned long long expected_size,
                       const char *expected_prefix,
                       int expected_last)
{
    struct stat st;
    size_t prefix_length =
        strcmp(expected_prefix, "-") == 0 ? 0 : strlen(expected_prefix);
    char *prefix = NULL;
    unsigned char last = 0;
    int fd = open_existing(path, O_RDONLY);

    if (fstat(fd, &st) != 0) {
        perror("fstat check");
        exit(1);
    }
    if ((unsigned long long)st.st_size != expected_size) {
        fprintf(stderr,
                "size mismatch for %s: expected %llu got %" PRIuMAX "\n",
                path, expected_size, (uintmax_t)st.st_size);
        exit(1);
    }

    if (prefix_length != 0) {
        prefix = malloc(prefix_length);
        if (prefix == NULL) {
            fprintf(stderr, "malloc failed\n");
            exit(1);
        }
        if (pread(fd, prefix, prefix_length, 0) != (ssize_t)prefix_length) {
            perror("pread prefix");
            exit(1);
        }
        if (memcmp(prefix, expected_prefix, prefix_length) != 0) {
            fprintf(stderr, "prefix mismatch for %s\n", path);
            exit(1);
        }
        free(prefix);
    }

    if (expected_size > 0 && expected_last >= 0) {
        if (pread(fd, &last, 1, (off_t)expected_size - 1) != 1) {
            perror("pread last byte");
            exit(1);
        }
        if (last != (unsigned char)expected_last) {
            fprintf(stderr,
                    "last-byte mismatch for %s: expected %u got %u\n",
                    path,
                    (unsigned int)(unsigned char)expected_last,
                    (unsigned int)last);
            exit(1);
        }
    }

    if (close(fd) != 0) {
        perror("close check");
        exit(1);
    }

    printf("check path=%s size=%llu blocks=%" PRIuMAX "\n",
           path, expected_size, (uintmax_t)st.st_blocks);
}

static void check_reserve_ahead_result(const char *path)
{
    unsigned long long cluster_bytes;
    unsigned long long expected_size;
    int fd = open_existing(path, O_RDONLY);

    cluster_bytes = fd_cluster_bytes(fd);
    if (close(fd) != 0) {
        perror("close reserve-ahead result");
        exit(1);
    }
    if (cluster_bytes == 0 ||
        cluster_bytes > ((unsigned long long)INT64_MAX - 1) / 4) {
        fprintf(stderr, "invalid reserve-ahead result geometry\n");
        exit(1);
    }
    expected_size = cluster_bytes * 4 + 1;
    check_file(path, expected_size, "A", 67);
}

static void check_near_full_result(const char *path)
{
    unsigned long long cluster_bytes;
    unsigned long long expected_size;
    int fd = open_existing(path, O_RDONLY);

    cluster_bytes = fd_cluster_bytes(fd);
    if (close(fd) != 0) {
        perror("close near-full result");
        exit(1);
    }
    if (cluster_bytes == 0 ||
        cluster_bytes > (unsigned long long)INT64_MAX / 2) {
        fprintf(stderr, "invalid near-full result geometry\n");
        exit(1);
    }
    expected_size = cluster_bytes * 2;
    check_file(path, expected_size, "A", 68);
}

int main(int argc, char **argv)
{
    const char *command;
    const char *path;
    int fd;

    if (argc < 2) {
		fprintf(stderr,
			"usage: %s keep|expect-enospc|size|truncate|"
			"reserve|reserve-clusters|extend-clusters|append|"
			"reserve-ahead-sequence|reserve-ahead-truncate|reserve-ahead-unlink|"
			"reserve-ahead-near-full|check-reserve-ahead|check-near-full|"
			"fill-leave-clusters|append-measure|minimal-blocks|check|blocks ...\n",
                argv[0]);
        return 2;
    }

    command = argv[1];

    if (strcmp(command, "keep") == 0 ||
        strcmp(command, "expect-enospc") == 0) {
        unsigned long long offset;
        unsigned long long length;
        unsigned long long expected_size;
        struct stat after;
        int result;

        if (argc != 6) {
            fprintf(stderr,
                    "usage: %s %s PATH OFFSET LENGTH EXPECTED_SIZE\n",
                    argv[0], command);
            return 2;
        }

        path = argv[2];
        offset = parse_number(argv[3]);
        length = parse_number(argv[4]);
        expected_size = parse_number(argv[5]);
        fd = open_create(path);

        errno = 0;
        result = fallocate(fd, FALLOC_FL_KEEP_SIZE,
                           (off_t)offset, (off_t)length);

        if (strcmp(command, "keep") == 0) {
            if (result != 0) {
                perror("fallocate(FALLOC_FL_KEEP_SIZE)");
                return 1;
            }
        } else {
            if (result == 0 || errno != ENOSPC) {
                fprintf(stderr,
                        "expected ENOSPC, result=%d errno=%d (%s)\n",
                        result, errno, strerror(errno));
                return 1;
            }
            if (fstat(fd, &after) != 0) {
                perror("fstat after ENOSPC");
                return 1;
            }
            if (after.st_blocks == 0) {
                fprintf(stderr,
                        "ENOSPC lost the clusters allocated before failure\n");
                return 1;
            }
            printf("enospc_partial_blocks=%" PRIuMAX "\n",
                   (uintmax_t)after.st_blocks);
        }

        require_size(fd, expected_size);
        close(fd);
        return 0;
    }

    if (strcmp(command, "size") == 0) {
        unsigned long long expected_size;

        if (argc != 4) {
            fprintf(stderr, "usage: %s size PATH EXPECTED_SIZE\n", argv[0]);
            return 2;
        }
        path = argv[2];
        expected_size = parse_number(argv[3]);
        fd = open_existing(path, O_RDONLY);
        require_size(fd, expected_size);
        close(fd);
        return 0;
    }

    if (strcmp(command, "truncate") == 0) {
        unsigned long long size;

        if (argc != 4) {
            fprintf(stderr, "usage: %s truncate PATH SIZE\n", argv[0]);
            return 2;
        }
        path = argv[2];
        size = parse_number(argv[3]);
        fd = open_existing(path, O_RDWR);
        if (ftruncate(fd, (off_t)size) != 0) {
            perror("ftruncate");
            return 1;
        }
        require_size(fd, size);
        close(fd);
        return 0;
    }

	if (strcmp(command, "reserve") == 0) {
        if (argc != 5) {
            fprintf(stderr, "usage: %s reserve PATH OFFSET LENGTH\n", argv[0]);
            return 2;
        }
        reserve_keep_size(argv[2],
                          parse_number(argv[3]),
                          parse_number(argv[4]));
		return 0;
	}

	if (strcmp(command, "reserve-clusters") == 0) {
		if (argc != 4) {
			fprintf(stderr,
				"usage: %s reserve-clusters PATH TARGET_CLUSTERS\n",
				argv[0]);
			return 2;
		}
		reserve_cluster_count(argv[2], 0, parse_number(argv[3]));
		return 0;
	}

	if (strcmp(command, "extend-clusters") == 0) {
		if (argc != 5) {
			fprintf(stderr,
				"usage: %s extend-clusters PATH CURRENT_CLUSTERS TARGET_CLUSTERS\n",
				argv[0]);
			return 2;
		}
		reserve_cluster_count(argv[2], parse_number(argv[3]),
				      parse_number(argv[4]));
		return 0;
	}

    if (strcmp(command, "append") == 0) {
        unsigned long long value;

        if (argc != 5) {
            fprintf(stderr, "usage: %s append PATH COUNT BYTE\n", argv[0]);
            return 2;
        }
        value = parse_number(argv[4]);
        if (value > 255) {
            fprintf(stderr, "byte value out of range: %llu\n", value);
            return 2;
        }
        append_bytes(argv[2], parse_number(argv[3]), (unsigned char)value);
        return 0;
    }

    if (strcmp(command, "reserve-ahead-sequence") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: %s reserve-ahead-sequence PATH\n", argv[0]);
            return 2;
        }
        reserve_ahead_sequence(argv[2]);
        return 0;
    }

    if (strcmp(command, "reserve-ahead-truncate") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: %s reserve-ahead-truncate PATH\n", argv[0]);
            return 2;
        }
        reserve_ahead_truncate(argv[2]);
        return 0;
    }

    if (strcmp(command, "reserve-ahead-unlink") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: %s reserve-ahead-unlink PATH\n", argv[0]);
            return 2;
        }
        reserve_ahead_unlink(argv[2]);
        return 0;
    }

    if (strcmp(command, "reserve-ahead-near-full") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: %s reserve-ahead-near-full PATH\n", argv[0]);
            return 2;
        }
        reserve_ahead_near_full(argv[2]);
        return 0;
    }

    if (strcmp(command, "check-reserve-ahead") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: %s check-reserve-ahead PATH\n", argv[0]);
            return 2;
        }
        check_reserve_ahead_result(argv[2]);
        return 0;
    }

    if (strcmp(command, "check-near-full") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: %s check-near-full PATH\n", argv[0]);
            return 2;
        }
        check_near_full_result(argv[2]);
        return 0;
    }

    if (strcmp(command, "fill-leave-clusters") == 0) {
        if (argc != 4) {
            fprintf(stderr,
                    "usage: %s fill-leave-clusters PATH LEAVE_CLUSTERS\n",
                    argv[0]);
            return 2;
        }
        fill_leave_clusters(argv[2], parse_number(argv[3]));
        return 0;
    }

    if (strcmp(command, "append-measure") == 0) {
        unsigned long long value;

        if (argc != 6) {
            fprintf(stderr,
                    "usage: %s append-measure PATH CLUSTERS CHUNK_BYTES BYTE\n",
                    argv[0]);
            return 2;
        }
        value = parse_number(argv[5]);
        if (value > 255) {
            fprintf(stderr, "byte value out of range: %llu\n", value);
            return 2;
        }
        append_measure_workload(argv[2], parse_number(argv[3]),
                                parse_number(argv[4]), (unsigned char)value);
        return 0;
    }

    if (strcmp(command, "minimal-blocks") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: %s minimal-blocks PATH\n", argv[0]);
            return 2;
        }
        require_minimal_allocation(argv[2]);
        return 0;
    }

    if (strcmp(command, "check") == 0) {
        long long last;

        if (argc != 6) {
            fprintf(stderr,
                    "usage: %s check PATH SIZE PREFIX LAST_BYTE_OR_-1\n",
                    argv[0]);
            return 2;
        }
        last = parse_signed_number(argv[5]);
        if (last < -1 || last > 255) {
            fprintf(stderr, "last byte out of range: %lld\n", last);
            return 2;
        }
        check_file(argv[2], parse_number(argv[3]), argv[4], (int)last);
        return 0;
    }

    if (strcmp(command, "blocks") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: %s blocks PATH EXPECTED_BLOCKS\n", argv[0]);
            return 2;
        }
        require_blocks(argv[2], parse_number(argv[3]));
        return 0;
    }

    fprintf(stderr, "unknown command: %s\n", command);
    return 2;
}
