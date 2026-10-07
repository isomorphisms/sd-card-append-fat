#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include <android/log.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <jni.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define main appendfat_arena_cli_main
#include "../../../tools/appendfat_arena.c"
#undef main

#define LOG_TAG "appendfat-arena"
#define ARENA_CAPACITY 4194304
#define PAYLOAD_BYTES 98317

static int test_passed = 0;
static char result_text[1024];

static void cleanup(const char *arena, const char *payload)
{
    char path[1024];

    unlink(arena);
    snprintf(path, sizeof(path), "%s.used", arena);
    unlink(path);
    snprintf(path, sizeof(path), "%s.lock", arena);
    unlink(path);
    unlink(payload);
}

static int write_payload(const char *path)
{
    unsigned char buffer[4096];
    size_t written = 0;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);

    if (fd < 0)
        return -1;

    while (written < PAYLOAD_BYTES) {
        size_t count = PAYLOAD_BYTES - written;
        size_t i;

        if (count > sizeof(buffer))
            count = sizeof(buffer);
        for (i = 0; i < count; ++i)
            buffer[i] = (unsigned char)((written + i + 37U) % 251U);

        if (write_all(fd, buffer, count) != 0) {
            int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
        written += count;
    }

    if (fsync(fd) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return close(fd);
}

static int verify_payload(const char *arena)
{
    unsigned char buffer[4096];
    size_t checked = 0;
    int fd = open(arena, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);

    if (fd < 0)
        return -1;

    while (checked < PAYLOAD_BYTES) {
        size_t count = PAYLOAD_BYTES - checked;
        size_t i;
        ssize_t got;

        if (count > sizeof(buffer))
            count = sizeof(buffer);
        do {
            got = pread(fd, buffer, count, (off_t)checked);
        } while (got < 0 && errno == EINTR);

        if (got != (ssize_t)count) {
            close(fd);
            errno = EIO;
            return -1;
        }
        for (i = 0; i < count; ++i) {
            unsigned char expected =
                (unsigned char)((checked + i + 37U) % 251U);
            if (buffer[i] != expected) {
                close(fd);
                errno = EILSEQ;
                return -1;
            }
        }
        checked += count;
    }

    {
        unsigned char zeroes[64];
        ssize_t got = pread(fd, zeroes, sizeof(zeroes), PAYLOAD_BYTES);
        size_t i;

        if (got != (ssize_t)sizeof(zeroes)) {
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
    }

    return close(fd);
}

static int run_test(const char *private_dir)
{
    char arena[1024];
    char used_path[1024];
    char payload[1024];
    struct stat st;
    off_t used = -1;

    if (snprintf(arena, sizeof(arena), "%s/cache.arena", private_dir) >=
            (int)sizeof(arena) ||
        snprintf(used_path, sizeof(used_path), "%s/cache.arena.used",
                 private_dir) >= (int)sizeof(used_path) ||
        snprintf(payload, sizeof(payload), "%s/payload.bin", private_dir) >=
            (int)sizeof(payload)) {
        errno = ENAMETOOLONG;
        return -1;
    }

    cleanup(arena, payload);

    if (command_create(arena, "4194304") != 0)
        return -1;
    if (write_payload(payload) != 0)
        return -1;
    if (command_append(arena, payload) != 0)
        return -1;
    if (read_used(used_path, &used) != 0)
        return -1;
    if (used != PAYLOAD_BYTES) {
        errno = EINVAL;
        return -1;
    }
    if (stat(arena, &st) != 0 || st.st_size != ARENA_CAPACITY) {
        errno = EINVAL;
        return -1;
    }
    if (verify_payload(arena) != 0)
        return -1;

    snprintf(result_text, sizeof(result_text),
             "PASS: C67 app-private arena\n"
             "capacity=%d bytes\nused=%d bytes\n"
             "verified=create + append + fsync + atomic .used + reopen + bytes\n"
             "No storage permission; no raw device; no mount/format.",
             ARENA_CAPACITY, PAYLOAD_BYTES);
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
                 "FAIL: C67 arena sandbox errno=%d (%s). "
                 "No writes attempted outside app-private storage.",
                 saved_errno, strerror(saved_errno));
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "%s", result_text);
    }

    show_toast(activity, result_text);
}
