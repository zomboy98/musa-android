#ifndef MORNYE_PRIVATE_MOV_H
#define MORNYE_PRIVATE_MOV_H
#include <stddef.h>
#include <stdint.h>

/* Experimental synchronous primitive. The caller owns private paths, key,
 * callback context and publication. The output must be inside a host-owned,
 * per-attempt private directory. Caller cleans the whole directory after the
 * terminal callback, including partial output. Nothing is registered. */
typedef int (*mornye_mov_cancel_fn)(void *context);
typedef void (*mornye_mov_terminal_fn)(void *context, int result);
enum { MORNYE_MOV_OK = 0, MORNYE_MOV_FAILED = 1, MORNYE_MOV_CANCELLED = 2 };
__attribute__((visibility("default"))) int mornye_private_mov(const char *input, const char *output,
                       const uint8_t *key, size_t key_len,
                       mornye_mov_cancel_fn cancel,
                       mornye_mov_terminal_fn terminal, void *context);
/* Borrows regular file descriptors and key synchronously. Until return, the
 * caller must keep both descriptors open with stable status flags, maintain an
 * immutable input snapshot and grant exclusive writes to a fresh 0600 candidate.
 * Other handles and aliases must not be able to mutate either inode. Callbacks
 * must preserve these conditions. The function does not own or retain handles
 * and leaves their offsets untouched. Terminal follows the last native write.
 * Success is neither source authentication nor authorization to publish. */
__attribute__((visibility("default"))) int mornye_private_mov_fd_v1(int input_fd, int candidate_fd,
                       const uint8_t *key, size_t key_len,
                       mornye_mov_cancel_fn cancel,
                       mornye_mov_terminal_fn terminal, void *context);
#endif
