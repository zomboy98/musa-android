#include "private_mov.h"
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
static int public_logs;
static void public_log(void *p, int level, const char *format, va_list args) { (void)p; (void)level; (void)format; (void)args; ++public_logs; }
static int cancel(void *p) { (void)p; return 0; }
static void terminal(void *p, int result) { *(int *)p = result + 1; }
int main(int argc, char **argv) {
    int private_first = argc == 2 && strcmp(argv[1], "private-first") == 0;
    void *private = private_first ? dlopen("./libmornye_private_mov.so", RTLD_NOW | RTLD_LOCAL) : NULL;
    void *util = dlopen("libavutil.so", RTLD_NOW | RTLD_GLOBAL);
    void *format = dlopen("libavformat.so", RTLD_NOW | RTLD_GLOBAL);
    if (!private_first) private = dlopen("./libmornye_private_mov.so", RTLD_NOW | RTLD_LOCAL);
    if (!util || !format || !private) return 1;
    void (*set_callback)(void (*)(void *, int, const char *, va_list)) = dlsym(util, "av_log_set_callback");
    void (*log)(void *, int, const char *, ...) = dlsym(util, "av_log");
    int (*run)(const char *, const char *, const uint8_t *, size_t, mornye_mov_cancel_fn, mornye_mov_terminal_fn, void *) = dlsym(private, "mornye_private_mov");
    if (!set_callback || !log || !run) return 2;
    uint8_t key[16]; for (int i = 0; i < 16; i++) key[i] = (uint8_t)(i * 13 + 7);
    set_callback(public_log); log(NULL, 16, "before");
    int result = -1, code = run("fixture.mp4", private_first ? "coexist-private-first.flac" : "coexist-public-first.flac", key, sizeof(key), cancel, terminal, &result);
    memset(key, 0, sizeof(key)); log(NULL, 16, "after");
    int ok = code == 0 && result == 1 && public_logs == 2;
    printf("coexist-%s: %s (callbacks=%d terminal=%d)\n", private_first ? "private-first" : "public-first", ok ? "PASS" : "FAIL", public_logs, result);
    return ok ? 0 : 3;
}
