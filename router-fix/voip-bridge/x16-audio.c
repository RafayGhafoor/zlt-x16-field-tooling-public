/*
 * x16-audio.c — duplex call-audio pump for the ZLT X16 (SIMCom PCMIO voice tap).
 *
 * The X16 has no ALSA call-audio device (card 0 is stub/dummy only), so the X28
 * design's `arecord | aplay` leg cannot be used. The only byte-level access to
 * VoLTE call audio is the vendor PCM tap:
 *
 *     libolinterface.so.1:  Sunsea_Audio_PCMIO_Open / SendPcm / Close
 *                           Sunsea_Audio_StartPlay / StopPlay / GetPlayState
 *         \-> /tmp/alsa_server_socket -> alsa_daemon -> agm_server -> ADSP
 *
 * This program turns that into two plain UDP streams on loopback, which is what
 * a WebRTC bridge can actually consume:
 *
 *     downlink:  output_cb(chunk)  -->  sendto 127.0.0.1:<dl-port>
 *     uplink:    recvfrom 127.0.0.1:<ul-port>  -->  SendPcm paced in frames
 *
 * Wire format is raw S16_LE, mono, --rate (default 8000), no headers.
 *
 * SAFETY
 *   - Never run this without a live call; it is a tap into call audio.
 *   - The vendor library masks signals, so every vendor call is wrapped with an
 *     alarm() watchdog and the process is safe to `kill -9`.
 *   - Nothing here touches the data call, QMI, modem firmware or ALSA routing.
 *
 * BUILD (host):
 *   zig cc -target arm-linux-gnueabihf.2.31 -O2 -o x16-audio x16-audio.c -ldl -lpthread
 *   (the plain arm-linux-gnueabihf target emits GLIBC_2.34 symbols; this device
 *    runs glibc 2.31 and will refuse to load them)
 *
 * RUN (device):
 *   x16-audio --ul-port 50005 --dl-port 50006 --dir remote
 *   x16-audio --ul-file ul8k.raw --dl-file dl8k.raw --seconds 20 --verbose   # test
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* ---- recovered ABI (DWARF: simcom/simcom-sdk/include/Sunsea_Audio.h) ----- */

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
typedef int (*fn_startplay)(const char *, int, int);
typedef int (*fn_stopplay)(void);
typedef int (*fn_getplaystate)(void);

/* ---- state --------------------------------------------------------------- */

static volatile sig_atomic_t g_stop = 0;
static int g_dl_sock = -1;              /* downlink UDP target (browser side)   */
static int g_ul_sock = -1;              /* uplink UDP source (browser side)     */
static struct sockaddr_in g_dl_addr;
static FILE *g_dl_file = NULL;          /* optional capture for verification    */

static unsigned long g_dl_frames = 0, g_dl_bytes = 0, g_dl_send_err = 0;
static unsigned long g_ul_frames = 0, g_ul_bytes = 0, g_ul_underrun = 0, g_ul_send_err = 0;
static unsigned long g_ul_fail_run = 0;
static int g_verbose = 0;

static volatile sig_atomic_t g_alarm_stage = 0;   /* 1 = open, 2 = close, 3 = stream */

static void on_sig(int sig) { (void)sig; g_stop = 1; }

/* The vendor library masks signals, so the only way out of a wedged call is to
 * leave the process. Say which stage hung first (via write(), which is
 * async-signal-safe) so the supervisor can tell "tap busy" from "tap lost". */
static void on_alarm(int sig)
{
    const char *m;
    (void)sig;
    switch (g_alarm_stage) {
    case 1:  m = "[pcm] FATAL: PCMIO_Open did not answer (vendor tap busy or wedged)\n"; break;
    case 2:  m = "[pcm] FATAL: PCMIO_Close did not answer\n"; break;
    default: m = "[pcm] FATAL: vendor call timed out\n"; break;
    }
    if (write(2, m, strlen(m)) < 0) { /* nothing more to do */ }
    _exit(7);
}

/* Called on the library's reader thread for every downlink chunk. Keep it
 * allocation-free and non-blocking: this thread is shared with call audio. */
static void dl_cb(const pcm_stream_data_s *d)
{
    if (!d || !d->valid || d->len == 0 || d->len > sizeof(d->data)) return;
    g_dl_frames++;
    g_dl_bytes += d->len;

    if (g_dl_file) { fwrite(d->data, 1, d->len, g_dl_file); fflush(g_dl_file); }
    if (g_dl_sock >= 0) {
        ssize_t n = sendto(g_dl_sock, d->data, d->len, MSG_DONTWAIT,
                           (struct sockaddr *)&g_dl_addr, sizeof(g_dl_addr));
        if (n < 0) g_dl_send_err++;
    }
    if (g_verbose && (g_dl_frames == 1 || g_dl_frames % 100 == 0))
        fprintf(stderr, "[dl] cb #%lu len=%u total=%lu\n", g_dl_frames, d->len, g_dl_bytes);
}

/* ---- uplink ring buffer -------------------------------------------------- */

static uint8_t *g_ring = NULL;
static size_t g_ring_cap = 0, g_ring_len = 0, g_ring_rd = 0;

static void ring_push(const uint8_t *src, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (g_ring_len == g_ring_cap) {          /* overflow: drop oldest byte */
            g_ring_rd = (g_ring_rd + 1) % g_ring_cap;
            g_ring_len--;
        }
        g_ring[(g_ring_rd + g_ring_len) % g_ring_cap] = src[i];
        g_ring_len++;
    }
}

static size_t ring_pop(uint8_t *dst, size_t n)
{
    size_t take = n < g_ring_len ? n : g_ring_len;
    for (size_t i = 0; i < take; i++) {
        dst[i] = g_ring[g_ring_rd];
        g_ring_rd = (g_ring_rd + 1) % g_ring_cap;
    }
    g_ring_len -= take;
    return take;
}

static struct timespec ts_add_ns(struct timespec t, long ns)
{
    t.tv_nsec += ns;
    while (t.tv_nsec >= 1000000000L) { t.tv_nsec -= 1000000000L; t.tv_sec++; }
    return t;
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s [options]\n"
        "  --ul-port N        UDP port to receive uplink PCM on (default 50005)\n"
        "  --dl-port N        UDP port to send downlink PCM to  (default 50006)\n"
        "  --dir local|remote|both   PCM tap direction (default remote)\n"
        "  --rate 8k|16k             sample rate (default 8k)\n"
        "  --frame 320|640|1280      PCM frame size in samples (default 320 = 40 ms)\n"
        "  --arm <wav>        call StartPlay(<wav>,1,path) first to arm the play state\n"
        "  --no-arm           never call StartPlay (default when --arm is omitted)\n"
        "  --ul-file <raw>    read uplink from a file (looping) instead of UDP  [test]\n"
        "  --dl-file <raw>    also write downlink to a file                      [test]\n"
        "  --seconds N        stop after N seconds (0 = run until signal)\n"
        "  --verbose          log per-frame stats\n", p);
}

int main(int argc, char **argv)
{
    const char *lib = "libolinterface.so.1";
    const char *arm_file = NULL, *ul_file = NULL, *dl_file = NULL;
    int ul_port = 50005, dl_port = 50006, seconds = 0, i;
    int play_started = 0;
    PCMIO_DIRECTION_E dir = PCMIO_DIRECTION_REMOTE;
    PCM_SAMPLE_RATE_E rate = PCM_SAMPLE_RATE_8K;
    unsigned int samples_per_frame = 320;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--ul-port") && i + 1 < argc) ul_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dl-port") && i + 1 < argc) dl_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ul-file") && i + 1 < argc) ul_file = argv[++i];
        else if (!strcmp(argv[i], "--dl-file") && i + 1 < argc) dl_file = argv[++i];
        else if (!strcmp(argv[i], "--arm") && i + 1 < argc) arm_file = argv[++i];
        else if (!strcmp(argv[i], "--no-arm")) arm_file = NULL;
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--verbose")) g_verbose = 1;
        else if (!strcmp(argv[i], "--dir") && i + 1 < argc) {
            const char *v = argv[++i];
            dir = !strcmp(v, "local") ? PCMIO_DIRECTION_LOCAL
                : !strcmp(v, "both")  ? PCMIO_DIRECTION_BOTH
                                      : PCMIO_DIRECTION_REMOTE;
        } else if (!strcmp(argv[i], "--rate") && i + 1 < argc) {
            rate = !strcmp(argv[++i], "16k") ? PCM_SAMPLE_RATE_16K : PCM_SAMPLE_RATE_8K;
        } else if (!strcmp(argv[i], "--frame") && i + 1 < argc) {
            unsigned int f = (unsigned int)atoi(argv[++i]);
            if (f != 320 && f != 640 && f != 1280) { usage(argv[0]); return 2; }
            samples_per_frame = f;
        } else { usage(argv[0]); return 2; }
    }

    unsigned int rate_hz = (rate == PCM_SAMPLE_RATE_16K) ? 16000u : 8000u;
    size_t frame_bytes = (size_t)samples_per_frame * 2;          /* S16 mono */
    long period_ns = (long)((unsigned long long)samples_per_frame * 1000000000ULL / rate_hz);

    void *h = dlopen(lib, RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen(%s): %s\n", lib, dlerror()); return 3; }

    fn_open  p_open  = (fn_open)dlsym(h, "Sunsea_Audio_PCMIO_Open");
    fn_send  p_send  = (fn_send)dlsym(h, "Sunsea_Audio_PCMIO_SendPcm");
    fn_close p_close = (fn_close)dlsym(h, "Sunsea_Audio_PCMIO_Close");
    fn_startplay p_startplay = (fn_startplay)dlsym(h, "Sunsea_Audio_StartPlay");
    fn_stopplay  p_stopplay  = (fn_stopplay)dlsym(h, "Sunsea_Audio_StopPlay");
    fn_getplaystate p_getplay = (fn_getplaystate)dlsym(h, "Sunsea_Audio_GetPlayState");

    if (!p_open || !p_send || !p_close) {
        fprintf(stderr, "missing PCMIO symbols (open=%p send=%p close=%p)\n",
                (void *)p_open, (void *)p_send, (void *)p_close);
        return 4;
    }

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    signal(SIGALRM, on_alarm);
    signal(SIGPIPE, SIG_IGN);

    /* ---- sockets (loopback only; nothing is exposed off-box) -------------- */
    if (!ul_file) {
        g_ul_sock = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
        if (g_ul_sock < 0) { perror("socket(ul)"); return 5; }
        struct sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = htons((uint16_t)ul_port);
        if (bind(g_ul_sock, (struct sockaddr *)&a, sizeof(a)) < 0) {
            perror("bind(ul)"); return 5;
        }
        fprintf(stderr, "[ul] listening udp 127.0.0.1:%d\n", ul_port);
    }

    g_dl_sock = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    if (g_dl_sock < 0) { perror("socket(dl)"); return 5; }
    memset(&g_dl_addr, 0, sizeof(g_dl_addr));
    g_dl_addr.sin_family = AF_INET;
    g_dl_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    g_dl_addr.sin_port = htons((uint16_t)dl_port);
    fprintf(stderr, "[dl] sending udp 127.0.0.1:%d\n", dl_port);

    if (dl_file) {
        g_dl_file = fopen(dl_file, "wb");
        if (!g_dl_file) fprintf(stderr, "cannot open %s: %s\n", dl_file, strerror(errno));
    }

    /* ---- open the tap ----------------------------------------------------- */
    PCMIO_ATTR_S attr;
    memset(&attr, 0, sizeof(attr));
    attr.work_mode = PCMIO_WORKMODE_INPUT_OUTPUT;
    attr.work_dir  = dir;
    attr.input_attr.channels    = PCM_CHANNEL_MONO;
    attr.input_attr.sample_rate = rate;
    attr.input_attr.format      = ENDIAN_LITTLE;
    attr.input_attr.frame_size  = samples_per_frame == 320 ? PCM_FRAME_SIZE_320
                                : samples_per_frame == 1280 ? PCM_FRAME_SIZE_1280
                                                            : PCM_FRAME_SIZE_640;
    attr.output_attr.channels    = PCM_CHANNEL_MONO;
    attr.output_attr.sample_rate = rate;
    attr.output_attr.format      = ENDIAN_LITTLE;
    attr.output_attr.frame_size  = attr.input_attr.frame_size;
    attr.output_attr.output_cb   = dl_cb;

    g_alarm_stage = 1;
    alarm(6);                                   /* never wedge on the open */
    int rc = p_open(&attr);
    g_alarm_stage = 0;
    alarm(0);
    fprintf(stderr, "[pcm] PCMIO_Open rc=%d mode=%d dir=%d rate=%u frame=%u\n",
            rc, attr.work_mode, attr.work_dir, rate_hz, samples_per_frame);
    fflush(stderr);
    if (rc != 0) { dlclose(h); return 6; }

    /* ---- optional: arm the remote play state ------------------------------ */
    if (arm_file && p_startplay) {
        int path_value = (dir == PCMIO_DIRECTION_LOCAL) ? 0 : 1;
        fprintf(stderr, "[pcm] StartPlay(%s, 1, %d) ...\n", arm_file, path_value);
        fflush(stderr);
        alarm(8);
        int prc = p_startplay(arm_file, 1, path_value);
        alarm(0);
        play_started = (prc == 0);
        fprintf(stderr, "[pcm] StartPlay rc=%d", prc);
        if (p_getplay) fprintf(stderr, " state=%d", p_getplay());
        fprintf(stderr, "\n");
        fflush(stderr);
    } else if (p_getplay) {
        fprintf(stderr, "[pcm] play state before streaming = %d\n", p_getplay());
    }

    /* ---- main paced loop -------------------------------------------------- */
    g_ring_cap = frame_bytes * 64;              /* 64 frames (~2.5 s of slack) */
    g_ring = calloc(1, g_ring_cap);
    uint8_t *frame = calloc(1, frame_bytes);
    if (!g_ring || !frame) {
        fprintf(stderr, "oom\n");
        p_close();
        fflush(NULL);
        _exit(6);
    }

    FILE *ulf = NULL;
    if (ul_file) {
        ulf = fopen(ul_file, "rb");
        if (!ulf) {
            /* Leaving with the tap open is what wedges alsa_daemon for the next
             * caller, so every early exit from here closes it first. */
            fprintf(stderr, "cannot open %s: %s\n", ul_file, strerror(errno));
            p_close();
            fflush(NULL);
            _exit(6);
        }
        fprintf(stderr, "[ul] source file %s (looping)\n", ul_file);
    }

    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    long frame_ms = period_ns / 1000000L;
    unsigned long tick = 0, ticks_limit = seconds > 0 ? (unsigned long)seconds * 1000u / (unsigned long)frame_ms : 0;

    fprintf(stderr, "[run] %u samples/frame @ %u Hz = %ld ms/frame%s\n",
            samples_per_frame, rate_hz, frame_ms,
            seconds ? "" : " (until signal)");
    fflush(stderr);

    /* Uplink pull: UDP packets are variable length (browser sends 20 ms Opus
     * payloads already resampled), so everything goes through the ring and the
     * frame boundary is decided here, not by the sender. */
    uint8_t tmp[4096];

    while (!g_stop) {
        /* 1. drain uplink sources */
        if (ulf) {
            size_t n = fread(tmp, 1, frame_bytes, ulf);
            if (n == 0) { rewind(ulf); n = fread(tmp, 1, frame_bytes, ulf); }
            if (n > 0) ring_push(tmp, n);
        } else if (g_ul_sock >= 0) {
            for (int k = 0; k < 32; k++) {
                ssize_t n = recv(g_ul_sock, tmp, sizeof(tmp), MSG_DONTWAIT);
                if (n <= 0) break;
                ring_push(tmp, (size_t)n);
            }
        }

        /* 2. build one frame, pad with silence on underrun */
        size_t got = ring_pop(frame, frame_bytes);
        if (got < frame_bytes) {
            memset(frame + got, 0, frame_bytes - got);
            g_ul_underrun++;
        }

        /* 3. push it into the call */
        pcm_stream_data_s pkt;
        memset(&pkt, 0, sizeof(pkt));
        pkt.valid = 1;
        pkt.len = (unsigned int)frame_bytes;
        memcpy(pkt.data, frame, frame_bytes);
        int src = p_send(&pkt);
        if (src != 0) { g_ul_send_err++; g_ul_fail_run++; } else { g_ul_fail_run = 0; }
        g_ul_frames++;
        g_ul_bytes += frame_bytes;

        /* The vendor write thread dies when the daemon stops the play stream
         * ("status has changed -----> stop writing") and never recovers on its
         * own. Close the tap properly before leaving: an abandoned client is
         * what wedges alsa_daemon for the next call, so a bare _exit() here
         * costs the next caller its audio. */
        if (g_ul_fail_run >= 20) {
            fprintf(stderr, "[ul] %lu consecutive send failures — tap is dead, closing before restart\n",
                    g_ul_fail_run);
            if (g_dl_file) fflush(g_dl_file);
            fflush(NULL);
            g_alarm_stage = 2;
            // The browser bridge never starts the vendor file player. Calling
            // StopPlay anyway is not a harmless no-op on this daemon: on this
            // firmware it can block and the watchdog then exits before Close,
            // leaving an abandoned PCMIO client behind. Only undo a StartPlay
            // that this process actually completed.
            if (play_started && p_stopplay) { alarm(3); p_stopplay(); alarm(0); }
            alarm(5);
            (void)p_close();
            alarm(0);
            _exit(9);
        }

        if (g_verbose && (g_ul_frames == 1 || g_ul_frames % 25 == 0))
            fprintf(stderr, "[ul] send #%lu rc=%d ring=%zu underrun=%lu dl_frames=%lu\n",
                    g_ul_frames, src, g_ring_len, g_ul_underrun, g_dl_frames);

        /* 4. absolute-time pacing so SendPcm cost does not accumulate drift */
        next = ts_add_ns(next, period_ns);
        tick++;
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);

        if (ticks_limit && tick >= ticks_limit) break;
    }

    fprintf(stderr, "[stop] loop ended, closing tap\n");
    fflush(stderr);

    g_alarm_stage = 2;
    if (play_started && p_stopplay) { alarm(4); int sr = p_stopplay(); alarm(0); fprintf(stderr, "[pcm] StopPlay rc=%d\n", sr); }
    alarm(5);
    int crc = p_close();
    alarm(0);
    g_alarm_stage = 0;
    fprintf(stderr, "[pcm] PCMIO_Close rc=%d\n", crc);
    fprintf(stderr, "[summary] ul_frames=%lu ul_bytes=%lu ul_underrun=%lu ul_err=%lu "
                    "dl_frames=%lu dl_bytes=%lu dl_err=%lu\n",
            g_ul_frames, g_ul_bytes, g_ul_underrun, g_ul_send_err,
            g_dl_frames, g_dl_bytes, g_dl_send_err);

    if (ulf) fclose(ulf);
    if (g_dl_file) fclose(g_dl_file);
    if (g_ul_sock >= 0) close(g_ul_sock);
    if (g_dl_sock >= 0) close(g_dl_sock);

    /* Do NOT dlclose(), free() or return through exit(): the vendor library
     * leaves its reader/writer threads and shared memory alive, and tearing the
     * handles down under them segfaults (observed rc=139). PCMIO_Close above is
     * the supported detach; leaving the rest to the kernel is the safe exit. */
    fflush(NULL);
    _exit(crc == 0 ? 0 : 8);
}
