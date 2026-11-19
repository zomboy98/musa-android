#include "private_mov.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*FdRun)(int, int, const uint8_t *, size_t,
                     mornye_mov_cancel_fn, mornye_mov_terminal_fn, void *);
typedef struct { int callbacks, result, checks, cancel_after, output, saw_output; } State;

static int cancel(void *context) {
    State *state = context;
    if (state->cancel_after == 0) {
        struct stat info;
        state->saw_output = fstat(state->output, &info) == 0 && info.st_size > 0;
        return state->saw_output;
    }
    return ++state->checks >= state->cancel_after;
}
static void terminal(void *context, int result) {
    State *state = context;
    ++state->callbacks;
    state->result = result;
}

static int verify(FdRun run, const char *source, const char *target, int wrong,
                  int cancel_after, int same_inode, int flags, int seed_output, int expected) {
    int input = open(source, O_RDONLY | O_CLOEXEC);
    int output = same_inode ? dup(input) :
        open(target, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | flags, 0600);
    if (input < 0 || output < 0) {
        if (input >= 0) close(input);
        if (output >= 0) close(output);
        return 1;
    }
    if ((seed_output && write(output, "sentinel", 8) != 8) ||
        lseek(input, 7, SEEK_SET) != 7 || lseek(output, 11, SEEK_SET) != 11) {
        close(output);
        close(input);
        return 1;
    }
    State state = {0, -1, 0, cancel_after, output, 0};
    uint8_t key[16];
    for (int i = 0; i < 16; ++i) key[i] = (uint8_t)(i * 13 + 7);
    if (wrong) key[0] ^= 1;
    int result = run(input, output, key, sizeof(key), cancel, terminal, &state);
    int borrowed = lseek(input, 0, SEEK_CUR) == (same_inode ? 11 : 7) &&
        lseek(output, 0, SEEK_CUR) == 11;
    struct stat info;
    char sentinel[8];
    int payload = fstat(output, &info) == 0 &&
        (expected != MORNYE_MOV_OK || info.st_size > 4) &&
        (!seed_output || (info.st_size == 8 &&
            pread(output, sentinel, sizeof(sentinel), 0) == sizeof(sentinel) &&
            memcmp(sentinel, "sentinel", sizeof(sentinel)) == 0)) &&
        (!(flags & O_APPEND) || info.st_size == 0);
    close(output);
    close(input);
    int ok = borrowed && payload && (cancel_after != 0 || state.saw_output) && state.callbacks == 1 &&
        result == state.result && result == expected;
    printf("%s %s\n", target, ok ? "PASS" : "FAIL");
    return !ok;
}

int main(void) {
    void *library = dlopen("./libmornye_private_mov.so", RTLD_NOW | RTLD_LOCAL);
    FdRun run = library ? (FdRun)dlsym(library, "mornye_private_mov_fd_v1") : NULL;
    if (!run) {
        puts("FD ABI unavailable");
        if (library) dlclose(library);
        return 2;
    }
    int failed = 0;
    const int no_cancel = 1000000;
    failed += verify(run, "fixture.mp4", "fd-ok.flac", 0, no_cancel, 0, 0, 0, MORNYE_MOV_OK);
    failed += verify(run, "fixture.mp4", "fd-wrong.flac", 1, no_cancel, 0, 0, 0, MORNYE_MOV_FAILED);
    failed += verify(run, "truncated.mp4", "fd-short.flac", 0, no_cancel, 0, 0, 0, MORNYE_MOV_FAILED);
    failed += verify(run, "corrupt-crc.mp4", "fd-crc.flac", 0, no_cancel, 0, 0, 0, MORNYE_MOV_FAILED);
    failed += verify(run, "fixture.mp4", "fd-cancel.flac", 0, 1, 0, 0, 0, MORNYE_MOV_CANCELLED);
    failed += verify(run, "fixture.mp4", "fd-cancel-later.flac", 0, 0, 0, 0, 0, MORNYE_MOV_CANCELLED);
    failed += verify(run, "fixture.mp4", "same-inode", 0, no_cancel, 1, 0, 0, MORNYE_MOV_FAILED);
    failed += verify(run, "fixture.mp4", "fd-append.flac", 0, no_cancel, 0, O_APPEND, 0, MORNYE_MOV_FAILED);
    failed += verify(run, "fixture.mp4", "fd-nonempty.flac", 0, no_cancel, 0, 0, 1, MORNYE_MOV_FAILED);
    int oversized = open("oversized.mp4", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (oversized < 0 || ftruncate(oversized, 512 * 1024 * 1024 + 1) < 0) return 2;
    close(oversized);
    failed += verify(run, "oversized.mp4", "fd-oversized.flac", 0, no_cancel, 0, 0, 0, MORNYE_MOV_FAILED);
    struct rlimit original;
    if (getrlimit(RLIMIT_FSIZE, &original) < 0 ||
        signal(SIGXFSZ, SIG_IGN) == SIG_ERR) return 2;
    struct rlimit limited = original;
    limited.rlim_cur = 512;
    if (setrlimit(RLIMIT_FSIZE, &limited) < 0) return 2;
    failed += verify(run, "fixture.mp4", "fd-write-fail.flac", 0, no_cancel, 0, 0, 0, MORNYE_MOV_FAILED);
    if (setrlimit(RLIMIT_FSIZE, &original) < 0) return 2;
    struct stat short_write;
    if (stat("fd-write-fail.flac", &short_write) < 0 || short_write.st_size != 512) ++failed;
    dlclose(library);
    return failed != 0;
}
