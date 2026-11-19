#include "private_mov.h"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/log.h>
#include <libavutil/mem.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>

static const int64_t private_byte_limit = 512LL * 1024 * 1024;
static const unsigned private_packet_limit = 2000000;
typedef struct { mornye_mov_cancel_fn fn; void *opaque; } Interrupt;
static int interrupted(void *p) {
    Interrupt *i = p;
    return i->fn && i->fn(i->opaque);
}
typedef struct { int fd; int64_t cursor; Interrupt *interrupt; } Descriptor;

static int read_descriptor(void *opaque, uint8_t *bytes, int size) {
    Descriptor *file = opaque;
    if (size < 0 || file->cursor > INT64_MAX - size) return AVERROR(EOVERFLOW);
    if (interrupted(file->interrupt)) return AVERROR_EXIT;
    ssize_t count;
    do { count = pread64(file->fd, bytes, size, file->cursor); } while (count < 0 && errno == EINTR);
    if (count < 0) return AVERROR(errno);
    if (count == 0) return AVERROR_EOF;
    file->cursor += count;
    return (int)count;
}

static int write_descriptor(void *opaque, const uint8_t *bytes, int size) {
    Descriptor *file = opaque;
    if (size < 0 || file->cursor > private_byte_limit - size) return AVERROR(EFBIG);
    int written = 0;
    while (written < size) {
        if (interrupted(file->interrupt)) return AVERROR_EXIT;
        ssize_t count = pwrite64(file->fd, bytes + written, size - written, file->cursor);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return AVERROR(errno);
        if (count == 0) return AVERROR(EIO);
        file->cursor += count;
        written += (int)count;
    }
    return written;
}

static int64_t seek_descriptor(void *opaque, int64_t offset, int flags) {
    Descriptor *file = opaque;
    if (interrupted(file->interrupt)) return AVERROR_EXIT;
    int64_t base;
    switch (flags & ~AVSEEK_FORCE) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = file->cursor; break;
    case AVSEEK_SIZE:
    case SEEK_END: {
        struct stat64 info;
        if (fstat64(file->fd, &info) < 0) return AVERROR(errno);
        if ((flags & ~AVSEEK_FORCE) == AVSEEK_SIZE) return info.st_size;
        base = info.st_size;
        break;
    }
    default: return AVERROR(EINVAL);
    }
    int64_t cursor;
    if (__builtin_add_overflow(base, offset, &cursor) ||
        cursor < 0 || cursor > private_byte_limit) return AVERROR(EINVAL);
    file->cursor = cursor;
    return cursor;
}

static AVIOContext *descriptor_io(Descriptor *file, int writing) {
    const int size = 32768;
    uint8_t *buffer = av_malloc(size);
    if (!buffer) return NULL;
    AVIOContext *io = avio_alloc_context(buffer, size, writing, file,
        writing ? NULL : read_descriptor, writing ? write_descriptor : NULL, seek_descriptor);
    if (!io) av_free(buffer);
    return io;
}

static void free_descriptor_io(AVIOContext **io) {
    if (*io) av_freep(&(*io)->buffer);
    avio_context_free(io);
}

static int deny_external_io(AVFormatContext *format, AVIOContext **io,
                            const char *url, int flags, AVDictionary **options) {
    (void)format; (void)io; (void)url; (void)flags; (void)options;
    return AVERROR(EACCES);
}

static int valid_descriptors(int input, int output) {
    struct stat64 in, out;
    int flags = fcntl(output, F_GETFL);
    return flags >= 0 && (flags & O_ACCMODE) == O_RDWR && !(flags & O_APPEND) &&
        fstat64(input, &in) == 0 && fstat64(output, &out) == 0 &&
        S_ISREG(in.st_mode) && S_ISREG(out.st_mode) && in.st_size > 0 &&
        in.st_size <= private_byte_limit &&
        out.st_size == 0 && out.st_nlink == 1 && out.st_uid == geteuid() &&
        (out.st_mode & 07777) == 0600 &&
        (in.st_dev != out.st_dev || in.st_ino != out.st_ino);
}

static pthread_once_t logging_once = PTHREAD_ONCE_INIT;
static void discard_private_log(void *object, int level, const char *format, va_list args) {
    (void)object; (void)level; (void)format; (void)args;
}
static void silence_private_log(void) { av_log_set_callback(discard_private_log); }
static void wipe(void *p, size_t n) {
    volatile unsigned char *v = p;
    while (n--) *v++ = 0;
}
static int drain(AVCodecContext *decoder, AVFrame *frame, int *frames) {
    int r;
    while ((r = avcodec_receive_frame(decoder, frame)) >= 0) {
        ++*frames;
        av_frame_unref(frame);
    }
    return r == AVERROR(EAGAIN) || r == AVERROR_EOF ? 0 : r;
}

static int private_mov(const char *input, const char *output, int input_fd, int candidate_fd,
                       const uint8_t *key, size_t key_len,
                       mornye_mov_cancel_fn cancel,
                       mornye_mov_terminal_fn terminal, void *context) {
    AVFormatContext *src = NULL, *dst = NULL;
    AVIOContext *input_io = NULL, *output_io = NULL;
    int by_descriptor = !input && !output;
    AVCodecContext *decoder = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    AVDictionary *options = NULL;
    Interrupt intr = { cancel, context };
    Descriptor source = {input_fd, 0, &intr}, candidate = {candidate_fd, 0, &intr};
    char hex[33] = {0};
    static const char digits[] = "0123456789abcdef";
    int status = MORNYE_MOV_FAILED, index = -1, frames = 0, r;
    int output_open = 0, output_fd = -1;
    unsigned packets = 0;
    char fd_path[64];

    /* This requires the isolated static libav linkage in build_android.ps1.
       Never link this primitive against the application's shared FFmpegKit. */
    pthread_once(&logging_once, silence_private_log);
    if (!key || key_len != 16 || !terminal ||
        (by_descriptor ? !valid_descriptors(input_fd, candidate_fd) :
         (!input || !output || strcmp(input, output) == 0))) goto done;
    if (interrupted(&intr)) { status = MORNYE_MOV_CANCELLED; goto done; }
    for (size_t i = 0; i < 16; ++i) {
        hex[i * 2] = digits[key[i] >> 4];
        hex[i * 2 + 1] = digits[key[i] & 15];
    }
    if (av_dict_set(&options, "decryption_key", hex, 0) < 0) goto done;
    wipe(hex, sizeof(hex));
    if (by_descriptor &&
        (av_dict_set(&options, "enable_drefs", "0", 0) < 0 ||
         av_dict_set(&options, "use_absolute_path", "0", 0) < 0)) goto done;
    src = avformat_alloc_context();
    if (!src) goto done;
    src->interrupt_callback = (AVIOInterruptCB){ interrupted, &intr };
    if (by_descriptor) {
        input_io = descriptor_io(&source, 0);
        if (!input_io) goto done;
        src->pb = input_io;
        src->flags |= AVFMT_FLAG_CUSTOM_IO;
        src->io_open = deny_external_io;
        src->max_streams = 32;
        src->probesize = 5 * 1024 * 1024;
        src->max_analyze_duration = 5 * AV_TIME_BASE;
    }
    r = avformat_open_input(&src, input, av_find_input_format("mov"), &options);
    if (r < 0 || av_dict_count(options)) goto done;
    if (avformat_find_stream_info(src, NULL) < 0) goto done;
    index = av_find_best_stream(src, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (index < 0 || src->streams[index]->codecpar->codec_id != AV_CODEC_ID_FLAC) goto done;
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_FLAC);
    decoder = avcodec_alloc_context3(codec);
    if (!codec || !decoder ||
        avcodec_parameters_to_context(decoder, src->streams[index]->codecpar) < 0) goto done;
    decoder->err_recognition = AV_EF_CRCCHECK | AV_EF_EXPLODE;
    if (avcodec_open2(decoder, codec, NULL) < 0) goto done;
    if (avformat_alloc_output_context2(&dst, NULL, "flac", output) < 0 || !dst) goto done;
    AVStream *out = avformat_new_stream(dst, NULL);
    if (!out || avcodec_parameters_copy(out->codecpar, src->streams[index]->codecpar) < 0) goto done;
    out->time_base = src->streams[index]->time_base;
    dst->interrupt_callback = (AVIOInterruptCB){ interrupted, &intr };
    if (by_descriptor) {
        output_io = descriptor_io(&candidate, 1);
        if (!output_io) goto done;
        dst->pb = output_io;
        dst->flags |= AVFMT_FLAG_CUSTOM_IO;
        dst->io_open = deny_external_io;
    } else {
        output_fd = open(output, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (output_fd < 0) goto done;
        snprintf(fd_path, sizeof(fd_path), "/proc/self/fd/%d", output_fd);
        if (avio_open2(&dst->pb, fd_path, AVIO_FLAG_WRITE, &dst->interrupt_callback, NULL) < 0) goto done;
        output_open = 1;
    }
    if (avformat_write_header(dst, NULL) < 0) goto done;
    packet = av_packet_alloc(); frame = av_frame_alloc();
    if (!packet || !frame) goto done;
    while ((r = av_read_frame(src, packet)) >= 0) {
        if (interrupted(&intr) || (by_descriptor && ++packets > private_packet_limit)) goto done;
        if (packet->stream_index == index) {
            if (avcodec_send_packet(decoder, packet) < 0 || drain(decoder, frame, &frames) < 0) goto done;
            av_packet_rescale_ts(packet, src->streams[index]->time_base, out->time_base);
            packet->stream_index = out->index;
            if (av_interleaved_write_frame(dst, packet) < 0) goto done;
        }
        av_packet_unref(packet);
    }
    if (r != AVERROR_EOF || avcodec_send_packet(decoder, NULL) < 0 ||
        drain(decoder, frame, &frames) < 0 || frames == 0 ||
        interrupted(&intr) || av_write_trailer(dst) < 0) goto done;
    if (output_io) {
        avio_flush(output_io);
        if (output_io->error < 0) goto done;
    }
    status = MORNYE_MOV_OK;
done:
    wipe(hex, sizeof(hex));
    av_dict_free(&options);
    av_packet_free(&packet); av_frame_free(&frame); avcodec_free_context(&decoder);
    avformat_close_input(&src);
    if (dst) { if (output_open && avio_closep(&dst->pb) < 0) status = MORNYE_MOV_FAILED; avformat_free_context(dst); }
    free_descriptor_io(&input_io);
    free_descriptor_io(&output_io);
    if (output_fd >= 0) close(output_fd);
    if (interrupted(&intr)) status = MORNYE_MOV_CANCELLED;
    /* The caller owns the per-attempt directory. Unlinking a pathname here
       could delete a replacement after a concurrent rename. */
    if (terminal) terminal(context, status);
    return status;
}

int mornye_private_mov(const char *input, const char *output,
                       const uint8_t *key, size_t key_len,
                       mornye_mov_cancel_fn cancel,
                       mornye_mov_terminal_fn terminal, void *context) {
    return private_mov(input, output, -1, -1, key, key_len, cancel, terminal, context);
}

int mornye_private_mov_fd_v1(int input_fd, int candidate_fd,
                             const uint8_t *key, size_t key_len,
                             mornye_mov_cancel_fn cancel,
                             mornye_mov_terminal_fn terminal, void *context) {
    return private_mov(NULL, NULL, input_fd, candidate_fd, key, key_len, cancel, terminal, context);
}
