#include "private_mov.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
static __attribute__((unused)) int verify_pcm(const char *path) {
    AVFormatContext *f = NULL; AVCodecContext *d = NULL; AVPacket *p = NULL; AVFrame *a = NULL;
    int good = 0, index, r; long samples = 0;
    if (avformat_open_input(&f, path, NULL, NULL) < 0 || avformat_find_stream_info(f, NULL) < 0) goto done;
    index = av_find_best_stream(f, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (index < 0 || f->streams[index]->codecpar->codec_id != AV_CODEC_ID_FLAC) goto done;
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_FLAC);
    d = avcodec_alloc_context3(codec); p = av_packet_alloc(); a = av_frame_alloc();
    if (!d || !p || !a || avcodec_parameters_to_context(d, f->streams[index]->codecpar) < 0 || avcodec_open2(d, codec, NULL) < 0) goto done;
    while ((r = av_read_frame(f, p)) >= 0) {
        if (p->stream_index == index) {
            if (avcodec_send_packet(d, p) < 0) goto done;
            while ((r = avcodec_receive_frame(d, a)) >= 0) {
                if (a->format != AV_SAMPLE_FMT_S16 || a->ch_layout.nb_channels != 1) { printf("pcm format=%d channels=%d\n", a->format, a->ch_layout.nb_channels); goto done; }
                const int16_t *pcm = (const int16_t *)a->data[0];
                for (int j = 0; j < a->nb_samples; ++j, ++samples)
                    if (pcm[j] != (int16_t)(((samples * 47) % 65536) - 32768)) { printf("pcm mismatch at %ld got=%d expected=%d\n", samples, pcm[j], (int)(int16_t)(((samples * 47) % 65536) - 32768)); goto done; }
                av_frame_unref(a);
            }
            if (r != AVERROR(EAGAIN) && r != AVERROR_EOF) goto done;
        }
        av_packet_unref(p);
    }
    good = r == AVERROR_EOF && samples == 12 * 4410;
    if (!good) printf("pcm samples=%ld read=%d\n", samples, r);
done:
    av_frame_free(&a); av_packet_free(&p); avcodec_free_context(&d); avformat_close_input(&f);
    return good;
}
typedef struct { int calls, terminal, result, cancel_after; } State;
static int (*mov_run)(const char *, const char *, const uint8_t *, size_t, mornye_mov_cancel_fn, mornye_mov_terminal_fn, void *);
static int cancel(void *p) { State *s = p; return ++s->calls >= s->cancel_after; }
static void terminal(void *p, int result) { State *s = p; s->terminal++; s->result = result; }
static int run(const char *name, const char *input, const char *output, int wrong, int limit, int expected) {
    uint8_t key[16]; State s = {0, 0, -1, limit};
    for (int i = 0; i < 16; i++) key[i] = (uint8_t)(i * 13 + 7);
    if (wrong) key[0] ^= 1;
    int result = mov_run(input, output, key, sizeof(key), cancel, terminal, &s);
    memset(key, 0, sizeof(key));
    int exists = access(output, F_OK) == 0;
    /* This build omits the FLAC demuxer. The runner decodes and compares the
       pulled output independently using verify_pcm.py. */
    int ok = result == expected && s.terminal == 1 && s.result == result && (result != MORNYE_MOV_OK || exists);
    printf("%s: %s (result=%d callbacks=%d terminal=%d exists=%d)\n", name, ok ? "PASS" : "FAIL", result, s.calls, s.terminal, exists);
    return !ok;
}
typedef struct { int replaced, terminal, result; } Race;
static int race_cancel(void *p) {
    Race *s = p;
    if (!s->replaced && access("race.flac", F_OK) == 0 && rename("race.flac", "race-owned.flac") == 0) {
        FILE *f = fopen("race.flac", "wb");
        if (f) { fputs("replacement", f); fclose(f); s->replaced = 1; }
    }
    return s->replaced;
}
static void race_terminal(void *p, int result) { Race *s = p; ++s->terminal; s->result = result; }
static int test_race(void) {
    uint8_t key[16]; Race s = {0, 0, -1}; char buf[16] = {0};
    for (int i = 0; i < 16; i++) key[i] = (uint8_t)(i * 13 + 7);
    int result = mov_run("fixture.mp4", "race.flac", key, sizeof(key), race_cancel, race_terminal, &s);
    memset(key, 0, sizeof(key));
    FILE *f = fopen("race.flac", "rb"); if (f) { fread(buf, 1, 11, f); fclose(f); }
    int ok = result == MORNYE_MOV_CANCELLED && s.terminal == 1 && s.result == result && strcmp(buf, "replacement") == 0;
    printf("replacement-race: %s\n", ok ? "PASS" : "FAIL"); return !ok;
}
int main(void) {
    void *library = dlopen("./libmornye_private_mov.so", RTLD_NOW | RTLD_LOCAL);
    if (!library || !(mov_run = dlsym(library, "mornye_private_mov"))) { puts("bridge load: FAIL"); return 2; }
    int failures = 0;
    failures += run("success", "fixture.mp4", "ok.flac", 0, 1000000, MORNYE_MOV_OK);
    failures += run("wrong-key", "fixture.mp4", "wrong.flac", 1, 1000000, MORNYE_MOV_FAILED);
    failures += run("truncated", "truncated.mp4", "truncated.flac", 0, 1000000, MORNYE_MOV_FAILED);
    failures += run("cancel", "fixture.mp4", "cancel.flac", 0, 3, MORNYE_MOV_CANCELLED);
    failures += run("cancel-later", "fixture.mp4", "cancel-later.flac", 0, 12, MORNYE_MOV_CANCELLED);
    failures += test_race();
    return failures ? 1 : 0;
}
