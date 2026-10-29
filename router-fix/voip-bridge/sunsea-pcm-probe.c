/*
 * sunsea-pcm-probe.c — minimal probe for the SIMCom PCMIO voice tap (ZLT X16).
 *
 * Purpose: prove that libolinterface.so.1's PCMIO API can be opened from an
 * ordinary process, report the result, and (optionally) inject a raw PCM file
 * into the uplink and log downlink callbacks.
 *
 * API recovered from DWARF in /usr/lib/libolinterface.so.1.0.0
 * (simcom/simcom-sdk/include/Sunsea_Audio.h). See docs/22-voip-audio-bridge.md.
 *
 * Build (host, cross):
 *   zig cc -target arm-linux-gnueabihf -O2 -o sunsea-pcm-probe sunsea-pcm-probe.c -ldl
 *
 * Run (device):
 *   ./sunsea-pcm-probe --open-only
 *   ./sunsea-pcm-probe --play /cache/hello.raw --seconds 12 --record /cache/dl.raw
 *
 * Frames are paced to real time: `frame` samples at `rate` Hz per iteration
 * (640 samples @ 8 kHz = 80 ms). Without --play the uplink carries silence so
 * the stream stays open while downlink is captured.
 *
 * SAFETY: no call control here. Do not run while a call is in an unknown state;
 * --play only makes sense during an active call.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <signal.h>
#include <time.h>

/* ---- recovered ABI ------------------------------------------------------ */

typedef enum { PCM_CHANNEL_MONO = 1, PCM_CHANNEL_STEREO = 2, PCM_CHANNEL_MAX = 3 } PCM_CHANNEL_E;
typedef enum { PCM_SAMPLE_RATE_8K = 1, PCM_SAMPLE_RATE_16K = 2, PCM_SAMPLE_RATE_MAX = 3 } PCM_SAMPLE_RATE_E;
typedef enum { ENDIAN_LITTLE = 0, ENDIAN_BIG = -1 } PCM_FORMAT_E;
typedef enum {
    PCM_FRAME_SIZE_NONE = 0,
    PCM_FRAME_SIZE_320 = 1,
    PCM_FRAME_SIZE_640 = 2,
    PCM_FRAME_SIZE_1280 = 3,
    PCM_FRAME_SIZE_MAX = 4
} PCM_FRAME_SIZE_E;
typedef enum {
    PCMIO_WORKMODE_NONE = 0,
    PCMIO_WORKMODE_INPUT = 1,
    PCMIO_WORKMODE_OUTPUT = 2,
    PCMIO_WORKMODE_INPUT_OUTPUT = 3
} PCMIO_WORKMODE_E;
typedef enum {
    PCMIO_DIRECTION_NONE = 0,
    PCMIO_DIRECTION_LOCAL = 1,
    PCMIO_DIRECTION_REMOTE = 2,
    PCMIO_DIRECTION_BOTH = 3,
    PCMIO_DIRECTION_MAX = 4
} PCMIO_DIRECTION_E;

typedef struct { int valid; unsigned int len; char data[5120]; } pcm_stream_data_s;

typedef void (*pcmio_output_ind_cb)(const pcm_stream_data_s *data);

typedef struct {
    PCM_CHANNEL_E     channels;
    PCM_SAMPLE_RATE_E sample_rate;
    PCM_FORMAT_E      format;
    PCM_FRAME_SIZE_E  frame_size;
} PCMIO_INPUT_ATTR_S;

typedef struct {
    PCM_CHANNEL_E        channels;
    PCM_SAMPLE_RATE_E    sample_rate;
    PCM_FORMAT_E         format;
    PCM_FRAME_SIZE_E     frame_size;
    pcmio_output_ind_cb  output_cb;
} PCMIO_OUTPUT_ATTR_S;

typedef struct {
    PCMIO_WORKMODE_E   work_mode;
    PCMIO_DIRECTION_E  work_dir;
    PCMIO_INPUT_ATTR_S input_attr;
    PCMIO_OUTPUT_ATTR_S output_attr;
} PCMIO_ATTR_S;

typedef int (*fn_open)(PCMIO_ATTR_S *);
typedef int (*fn_send)(pcm_stream_data_s *);
typedef int (*fn_close)(void);
typedef int (*fn_startplay)(const char *filename, int repeat_value, int path_value);
typedef int (*fn_stopplay)(void);
typedef int (*fn_getplaystate)(void);
typedef int (*fn_startrec)(int record_type);
typedef int (*fn_stoprec)(void);

/* ---- state -------------------------------------------------------------- */

static volatile sig_atomic_t g_stop = 0;
static FILE *g_rec = NULL;
static unsigned long g_dl_frames = 0, g_dl_bytes = 0;
static unsigned long g_ul_frames = 0, g_ul_bytes = 0;

static void on_sig(int sig) { (void)sig; g_stop = 1; }

static void dl_cb(const pcm_stream_data_s *d)
{
    if (!d || !d->valid || d->len == 0) return;
    g_dl_frames++;
    g_dl_bytes += d->len;
    if (g_rec) {
        fwrite(d->data, 1, d->len, g_rec);
        fflush(g_rec);
    }
    if (g_dl_frames == 1 || g_dl_frames % 50 == 0)
        fprintf(stderr, "downlink cb #%lu len=%u bytes_total=%lu\n",
                g_dl_frames, d->len, g_dl_bytes);
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s [options]\n"
        "  --open-only            open+close the PCM tap, report rc, do nothing else\n"
        "  --play-file <wav>      vendor StartPlay() path: play WAV into the call\n"
        "  --no-pcmio             do not open PCMIO tap during StartPlay\n"
        "  --repeat N             StartPlay repeat value (default 1)\n"
        "  --rec-type 1|2|3       StartRecord(): 1 local, 2 remote, 3 both\n"
        "  --dir local|remote|both  default remote\n"
        "  --rate 8k|16k           default 8k\n"
        "  --frame 320|640|1280    default 640 (80 ms @8k)\n"
        "  --play <raw file>       inject raw S16_LE mono PCM (uplink)\n"
        "  --record <raw file>     write downlink PCM (raw S16_LE mono)\n"
        "  --seconds N             run time when --play is used (default 10)\n"
        "  --mode in|out|both      default both\n", p);
}

int main(int argc, char **argv)
{
    const char *lib = "libolinterface.so.1";
    const char *play = NULL, *rec = NULL, *playfile = NULL;
    int repeat = 1, rectype = 0;
    PCMIO_DIRECTION_E dir = PCMIO_DIRECTION_REMOTE;
    PCM_SAMPLE_RATE_E rate = PCM_SAMPLE_RATE_8K;
    PCM_FRAME_SIZE_E frame = PCM_FRAME_SIZE_640;
    PCMIO_WORKMODE_E mode = PCMIO_WORKMODE_INPUT_OUTPUT;
    int open_only = 0, no_pcmio = 0, seconds = 10, i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--open-only")) open_only = 1;
        else if (!strcmp(argv[i], "--no-pcmio")) no_pcmio = 1;
        else if (!strcmp(argv[i], "--play") && i + 1 < argc) play = argv[++i];
        else if (!strcmp(argv[i], "--play-file") && i + 1 < argc) playfile = argv[++i];
        else if (!strcmp(argv[i], "--repeat") && i + 1 < argc) repeat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rec-type") && i + 1 < argc) rectype = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--record") && i + 1 < argc) rec = argv[++i];
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dir") && i + 1 < argc) {
            const char *v = argv[++i];
            dir = !strcmp(v, "local") ? PCMIO_DIRECTION_LOCAL
                : !strcmp(v, "both")  ? PCMIO_DIRECTION_BOTH
                                      : PCMIO_DIRECTION_REMOTE;
        } else if (!strcmp(argv[i], "--rate") && i + 1 < argc) {
            rate = !strcmp(argv[++i], "16k") ? PCM_SAMPLE_RATE_16K : PCM_SAMPLE_RATE_8K;
        } else if (!strcmp(argv[i], "--frame") && i + 1 < argc) {
            int f = atoi(argv[++i]);
            frame = f == 320 ? PCM_FRAME_SIZE_320
                  : f == 1280 ? PCM_FRAME_SIZE_1280
                              : PCM_FRAME_SIZE_640;
        } else if (!strcmp(argv[i], "--mode") && i + 1 < argc) {
            const char *v = argv[++i];
            mode = !strcmp(v, "in")  ? PCMIO_WORKMODE_INPUT
                 : !strcmp(v, "out") ? PCMIO_WORKMODE_OUTPUT
                                     : PCMIO_WORKMODE_INPUT_OUTPUT;
        } else { usage(argv[0]); return 2; }
    }

    void *h = dlopen(lib, RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen(%s): %s\n", lib, dlerror()); return 3; }

    fn_open  p_open  = (fn_open)dlsym(h, "Sunsea_Audio_PCMIO_Open");
    fn_send  p_send  = (fn_send)dlsym(h, "Sunsea_Audio_PCMIO_SendPcm");
    fn_close p_close = (fn_close)dlsym(h, "Sunsea_Audio_PCMIO_Close");
    fn_startplay p_startplay = (fn_startplay)dlsym(h, "Sunsea_Audio_StartPlay");
    fn_stopplay  p_stopplay  = (fn_stopplay)dlsym(h, "Sunsea_Audio_StopPlay");
    fn_getplaystate p_getplay = (fn_getplaystate)dlsym(h, "Sunsea_Audio_GetPlayState");
    fn_startrec  p_startrec  = (fn_startrec)dlsym(h, "Sunsea_Audio_StartRecord");
    fn_stoprec   p_stoprec   = (fn_stoprec)dlsym(h, "Sunsea_Audio_StopRecord");

    /* ---- file-based vendor path: PCMIO_Open then StartPlay / StartRecord - */
    if (playfile || rectype) {
        if (!p_startplay || !p_stopplay) {
            fprintf(stderr, "StartPlay symbols missing\n");
            dlclose(h);
            return 8;
        }
        int path_value = (dir == PCMIO_DIRECTION_LOCAL) ? 0 : 1;
        if (!no_pcmio) {
            PCMIO_ATTR_S fattr;
            memset(&fattr, 0, sizeof(fattr));
            fattr.work_mode = PCMIO_WORKMODE_INPUT_OUTPUT;
            fattr.work_dir  = dir;
            fattr.input_attr.channels    = PCM_CHANNEL_MONO;
            fattr.input_attr.sample_rate = rate;
            fattr.input_attr.format      = ENDIAN_LITTLE;
            fattr.input_attr.frame_size  = frame;
            fattr.output_attr.channels    = PCM_CHANNEL_MONO;
            fattr.output_attr.sample_rate = rate;
            fattr.output_attr.format      = ENDIAN_LITTLE;
            fattr.output_attr.frame_size  = frame;
            fattr.output_attr.output_cb   = dl_cb;
            int orc = p_open(&fattr);
            fprintf(stderr, "PCMIO_Open rc=%d\n", orc);
            fflush(stderr);
        }
        if (rec) {
            g_rec = fopen(rec, "wb");
            if (!g_rec) fprintf(stderr, "cannot open %s\n", rec);
        }
        if (playfile) {
            fprintf(stderr, "calling StartPlay(%s, %d, %d) ...\n", playfile, repeat, path_value);
            fflush(stderr);
            int rc0 = p_startplay(playfile, repeat, path_value);
            fprintf(stderr, "StartPlay rc=%d\n", rc0);
            fflush(stderr);
            if (p_getplay) fprintf(stderr, "GetPlayState=%d\n", p_getplay());
        }
        if (rectype && p_startrec) {
            int rc1 = p_startrec(rectype);
            fprintf(stderr, "StartRecord(type=%d) rc=%d\n", rectype, rc1);
            fflush(stderr);
        }
        signal(SIGINT, on_sig);
        signal(SIGTERM, on_sig);
        int was_playing = 0;
        for (i = 0; i < seconds * 10 && !g_stop; i++) {
            usleep(100000);
            if (i % 10 == 0 && p_getplay) {
                int st = p_getplay();
                fprintf(stderr, "t=%ds GetPlayState=%d\n", i/10, st);
                if (st != 0) was_playing = 1;
                if (was_playing && st == 0 && i >= 20) {
                    fprintf(stderr, "playback finished (state=0)\n");
                    break;
                }
            }
        }
        if (rectype && p_stoprec) fprintf(stderr, "StopRecord rc=%d\n", p_stoprec());
        if (playfile && p_stopplay) fprintf(stderr, "StopPlay rc=%d\n", p_stopplay());
        if (g_rec) { fclose(g_rec); g_rec = NULL; }
        if (!no_pcmio) {
            fprintf(stderr, "PCMIO_Close rc=%d dl_frames=%lu dl_bytes=%lu\n",
                    p_close(), g_dl_frames, g_dl_bytes);
        }
        dlclose(h);
        return 0;
    }
    if (!p_open || !p_send || !p_close) {
        fprintf(stderr, "missing symbols (open=%p send=%p close=%p)\n",
                (void *)p_open, (void *)p_send, (void *)p_close);
        return 4;
    }

    PCMIO_ATTR_S attr;
    memset(&attr, 0, sizeof(attr));
    attr.work_mode = mode;
    attr.work_dir  = dir;
    attr.input_attr.channels    = PCM_CHANNEL_MONO;
    attr.input_attr.sample_rate = rate;
    attr.input_attr.format      = ENDIAN_LITTLE;
    attr.input_attr.frame_size  = frame;
    attr.output_attr.channels    = PCM_CHANNEL_MONO;
    attr.output_attr.sample_rate = rate;
    attr.output_attr.format      = ENDIAN_LITTLE;
    attr.output_attr.frame_size  = frame;
    attr.output_attr.output_cb   = dl_cb;

    fprintf(stderr, "attr: sizeof=%zu mode=%d dir=%d rate=%d frame=%d\n",
            sizeof(attr), attr.work_mode, attr.work_dir,
            attr.input_attr.sample_rate, attr.input_attr.frame_size);

    int rc = p_open(&attr);
    fprintf(stderr, "PCMIO_Open rc=%d (%s)\n", rc, rc ? "nonzero" : "ok");
    if (rc != 0) { dlclose(h); return 5; }

    if (open_only) {
        rc = p_close();
        fprintf(stderr, "PCMIO_Close rc=%d\n", rc);
        dlclose(h);
        return rc == 0 ? 0 : 6;
    }

    if (rec) {
        g_rec = fopen(rec, "wb");
        if (!g_rec) { fprintf(stderr, "cannot open %s\n", rec); }
    }

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    FILE *pf = play ? fopen(play, "rb") : NULL;
    if (play && !pf) fprintf(stderr, "cannot open %s\n", play);

    /* Frame = frame_size samples at `rate`; 16-bit mono => 2 bytes/sample. */
    unsigned int samples = frame == PCM_FRAME_SIZE_320 ? 320
                         : frame == PCM_FRAME_SIZE_1280 ? 1280 : 640;
    unsigned int bytes = samples * 2;
    unsigned char *buf = calloc(1, bytes);
    pcm_stream_data_s pkt;
    if (!buf) return 7;

    /* real-time pacing */
    unsigned int hz = (rate == PCM_SAMPLE_RATE_16K) ? 16000u : 8000u;
    long period_ns = (long)((unsigned long long)samples * 1000000000ULL / hz);
    struct timespec tick = { period_ns / 1000000000L, period_ns % 1000000000L };

    unsigned long total_frames = (unsigned long)(seconds * (long)hz / (long)samples);
    fprintf(stderr, "pacing: %u samples @ %u Hz = %ld ms/frame, %lu frames\n",
            samples, hz, period_ns / 1000000L, total_frames);

    for (unsigned long f = 0; f < total_frames && !g_stop; f++) {
        int n = 0;
        if (pf) {
            n = (int)fread(buf, 1, bytes, pf);
            if (n <= 0) { rewind(pf); n = (int)fread(buf, 1, bytes, pf); }
        }
        if (n <= 0) { memset(buf, 0, bytes); n = (int)bytes; }

        memset(&pkt, 0, sizeof(pkt));
        pkt.valid = 1;
        pkt.len = (unsigned int)n;
        memcpy(pkt.data, buf, (size_t)n);
        int src = p_send(&pkt);
        g_ul_frames++;
        g_ul_bytes += (unsigned long)n;
        if (g_ul_frames == 1 || g_ul_frames % 50 == 0)
            fprintf(stderr, "uplink send #%lu len=%d rc=%d\n",
                    g_ul_frames, n, src);
        nanosleep(&tick, NULL);
    }

    free(buf);
    if (pf) fclose(pf);
    if (g_rec) fclose(g_rec);

    rc = p_close();
    fprintf(stderr, "PCMIO_Close rc=%d\n", rc);
    fprintf(stderr, "summary: ul_frames=%lu ul_bytes=%lu dl_frames=%lu dl_bytes=%lu\n",
            g_ul_frames, g_ul_bytes, g_dl_frames, g_dl_bytes);
    dlclose(h);
    return 0;
}
