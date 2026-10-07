#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include "../../../lib/appendfat_arena.h"

#include <android/log.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef TARGET_ABI
#define TARGET_ABI "unknown"
#endif

#define LOG_TAG "appendfat-arena"
#define ARENA_CAPACITY 4194304U
#define PAYLOAD_BYTES 98317U

static int test_passed;
static char result_text[1024];

static void cleanup(const char *arena)
{
    char path[1024];

    unlink(arena);
    snprintf(path, sizeof(path), "%s.used", arena);
    unlink(path);
    snprintf(path, sizeof(path), "%s.lock", arena);
    unlink(path);
}

static int verify_zero_tail(const char *path)
{
    unsigned char zeroes[64];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    ssize_t count;
    size_t i;

    if (fd < 0)
        return -1;
    do {
        count = pread(fd, zeroes, sizeof(zeroes), PAYLOAD_BYTES);
    } while (count < 0 && errno == EINTR);
    if (count != (ssize_t)sizeof(zeroes)) {
        close(fd);
        errno = EIO;
        return -1;
    }
    for (i = 0; i < sizeof(zeroes); ++i) {
        if (zeroes[i] != 0) {
            close(fd);
            errno = EILSEQ;
            return -1;
        }
    }
    return close(fd);
}

static int run_test(const char *private_dir)
{
    char path[1024];
    appendfat_arena arena;
    unsigned char write_buffer[4096];
    unsigned char read_buffer[4096];
    size_t written = 0;

    if (snprintf(path, sizeof(path), "%s/cache.arena", private_dir) >=
        (int)sizeof(path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    cleanup(path);

    if (appendfat_arena_create(path, ARENA_CAPACITY) != 0)
        return -1;
    if (appendfat_arena_open(&arena, path, 1) != 0)
        return -1;

    while (written < PAYLOAD_BYTES) {
        size_t amount = PAYLOAD_BYTES - written;
        size_t i;

        if (amount > sizeof(write_buffer))
            amount = sizeof(write_buffer);
        for (i = 0; i < amount; ++i)
            write_buffer[i] =
                (unsigned char)((written + i + 37U) % 251U);
        if (appendfat_arena_append(&arena, write_buffer, amount) != 0) {
            appendfat_arena_close(&arena);
            return -1;
        }
        written += amount;
    }
    if (appendfat_arena_committed(&arena) != 0 ||
        appendfat_arena_cursor(&arena) != PAYLOAD_BYTES ||
        appendfat_arena_commit(&arena) != 0) {
        appendfat_arena_close(&arena);
        return -1;
    }
    appendfat_arena_close(&arena);

    /* Reopen proves the sidecar commit, not just the in-memory cursor. */
    if (appendfat_arena_open(&arena, path, 0) != 0)
        return -1;
    if (appendfat_arena_capacity(&arena) != ARENA_CAPACITY ||
        appendfat_arena_committed(&arena) != PAYLOAD_BYTES) {
        appendfat_arena_close(&arena);
        errno = EINVAL;
        return -1;
    }

    written = 0;
    while (written < PAYLOAD_BYTES) {
        size_t amount = 0;
        size_t i;

        if (appendfat_arena_read(&arena, written, read_buffer,
                                 sizeof(read_buffer), &amount) != 0 ||
            amount == 0) {
            appendfat_arena_close(&arena);
            return -1;
        }
        for (i = 0; i < amount; ++i) {
            unsigned char expected =
                (unsigned char)((written + i + 37U) % 251U);
            if (read_buffer[i] != expected) {
                appendfat_arena_close(&arena);
                errno = EILSEQ;
                return -1;
            }
        }
        written += amount;
    }
    appendfat_arena_close(&arena);

    if (verify_zero_tail(path) != 0)
        return -1;

    snprintf(result_text, sizeof(result_text),
             "PASS: app-private arena (%s)\n"
             "capacity=%u bytes\nused=%u bytes\n"
             "verified=library create + append + commit + reopen + bytes\n"
             "No storage permission; no raw device; no mount/format.",
             TARGET_ABI, ARENA_CAPACITY, PAYLOAD_BYTES);
    return 0;
}

static void show_toast(ANativeActivity *activity, const char *text)
{
    JNIEnv *env = NULL;
    int attached = 0;
    jclass toast_class;
    jmethodID make_text;
    jmethodID show;
    jstring message;
    jobject toast;

    if ((*activity->vm)->GetEnv(activity->vm, (void **)&env,
                               JNI_VERSION_1_6) != JNI_OK) {
        if ((*activity->vm)->AttachCurrentThread(activity->vm,
                                                  &env, NULL) != JNI_OK)
            return;
        attached = 1;
    }

    toast_class = (*env)->FindClass(env, "android/widget/Toast");
    if (toast_class == NULL)
        goto done;
    make_text = (*env)->GetStaticMethodID(
        env, toast_class, "makeText",
        "(Landroid/content/Context;Ljava/lang/CharSequence;I)Landroid/widget/Toast;");
    show = (*env)->GetMethodID(env, toast_class, "show", "()V");
    if (make_text == NULL || show == NULL)
        goto done;

    message = (*env)->NewStringUTF(env, text);
    if (message == NULL)
        goto done;
    toast = (*env)->CallStaticObjectMethod(env, toast_class, make_text,
                                           activity->clazz, message, 1);
    if (toast != NULL)
        (*env)->CallVoidMethod(env, toast, show);
    (*env)->DeleteLocalRef(env, message);

done:
    if (attached)
        (*activity->vm)->DetachCurrentThread(activity->vm);
}

static void paint_window(ANativeActivity *activity, ANativeWindow *window)
{
    ANativeWindow_Buffer buffer;
    uint32_t color = test_passed ? 0xff177d37U : 0xff8b1e1eU;
    int y;

    (void)activity;
    ANativeWindow_setBuffersGeometry(window, 0, 0, WINDOW_FORMAT_RGBA_8888);
    if (ANativeWindow_lock(window, &buffer, NULL) != 0)
        return;
    for (y = 0; y < buffer.height; ++y) {
        uint32_t *row = (uint32_t *)((char *)buffer.bits +
                                     (size_t)y * (size_t)buffer.stride * 4U);
        int x;
        for (x = 0; x < buffer.width; ++x)
            row[x] = color;
    }
    ANativeWindow_unlockAndPost(window);
}

JNIEXPORT void ANativeActivity_onCreate(ANativeActivity *activity,
                                        void *saved_state,
                                        size_t saved_state_size)
{
    int saved_errno;
    (void)saved_state;
    (void)saved_state_size;

    activity->callbacks->onNativeWindowCreated = paint_window;
    if (run_test(activity->internalDataPath) == 0) {
        test_passed = 1;
        __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "%s", result_text);
    } else {
        saved_errno = errno;
        snprintf(result_text, sizeof(result_text),
                 "FAIL: arena sandbox (%s) errno=%d (%s). "
                 "No writes attempted outside app-private storage.",
                 TARGET_ABI, saved_errno, strerror(saved_errno));
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "%s", result_text);
    }
    show_toast(activity, result_text);
}
