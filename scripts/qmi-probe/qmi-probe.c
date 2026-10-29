/*
 * qmi-probe -- read-only QMI over QRTR, no libqmi, no libqrtr-glib.
 *
 * Why this exists: libqmi 1.34 (qmanager/dependencies/qmi) reads band
 * capability, the system selection preference and CA, but has no command for
 * the LTE/NR cell-lock GETs, and every call costs a libgobject client fork on a
 * 1-core box. This speaks the wire format directly: one 28 KB static binary,
 * any NAS/DMS GET.
 *
 * TRANSPORT, as measured on the X16 (SDX65, kernel 5.4.210-perf) on 2026-10-29
 * with an LD_PRELOAD shim around the working qmicli:
 *
 *   1. AF_QIPCRTR datagram. On QRTR the QMI message carries NO QMUX header:
 *        u8 type(0=request) | u16 txn | u16 msg_id | u16 body_len | TLVs...
 *   2. Service discovery goes through the kernel nameserver: bind nothing, ask
 *      getsockname() for the local node id, then send a NEW_LOOKUP control
 *      packet to (local_node, QRTR_PORT_CTRL) and read NEW_SERVER replies on
 *      the same socket. That reply carries the node/port to talk to -- on this
 *      unit NAS is node 3 port 68. Then connect() a fresh socket to it.
 *   3. Each connected socket is its own QMI client, so nothing here disturbs
 *      QCMAP/dialer/the RIL.
 *
 * THE TRAP, and the reason bunnylock's cpp/qrtr.c does not work here as written:
 * the QRTR control ABI was renumbered. Android's downstream kernels (what
 * bunnylock targets) use   QRTR_PORT_CTRL=2, NEW_LOOKUP=5, NEW_SERVER=3 --
 * mainline, and this vendor's backport, use
 *                          QRTR_PORT_CTRL=0xFFFFFFFE,
 *                          NEW_LOOKUP=10, NEW_SERVER=4.
 * Sent with the old numbers this kernel answers ENODEV (no such node) for the
 * lookup and ECONNRESET for a real node: a silent, confusing failure. This
 * program tries the modern set first, then the legacy one, and says which
 * answered.
 *
 * Every subcommand is a GET (read-only). Nothing here writes a modem setting;
 * see README.md for why that line is deliberate.
 *
 * Build: ./build.sh   (zig cc -target arm-linux-musleabihf -static)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

/* musl's <sys/socket.h> already defines AF_QIPCRTR; the kernel ABI structs are
 * not in the musl sysroot, so they are repeated here (identical layout). */
#ifndef AF_QIPCRTR
#define AF_QIPCRTR 42
#endif

struct sockaddr_qrtr {
    unsigned short sq_family;
    unsigned int sq_node;
    unsigned int sq_port;
};

struct qrtr_ctrl_pkt {
    uint32_t cmd;
    union {
        struct {
            uint32_t service;
            uint32_t instance;
            uint32_t node;
            uint32_t port;
        } server;
        struct {
            uint32_t node;
            uint32_t port;
        } client;
    };
};

/* The two control ABIs. Order matters: modern first (this device). */
struct qrtr_abi {
    const char *name;
    uint32_t ctrl_port;
    uint32_t new_lookup;
    uint32_t new_server;
};

static const struct qrtr_abi ABIS[] = {
    {"modern (mainline: ctrl 0xFFFFFFFE, lookup 10)", 0xFFFFFFFEu, 10, 4},
    {"legacy (android: ctrl 2, lookup 5)", 2, 5, 3},
};

#define QMI_SERVICE_DMS 0x02
#define QMI_SERVICE_NAS 0x03

#define QMI_HEADER 7
#define QMI_MAX 65536
#define QMI_TYPE_RESPONSE 2
#define TLV_HEADER 3

#define LOOKUP_TIMEOUT_MS 1500

static const char *abi_used = NULL;

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((int64_t)ts.tv_sec * 1000) + (ts.tv_nsec / 1000000);
}

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* 1 readable, 0 deadline passed, -errno on a failed wait. */
static int wait_readable(int fd, int64_t deadline) {
    for (;;) {
        int64_t left = deadline - now_ms();
        if (left <= 0) return 0;
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int ready = poll(&p, 1, (int)left);
        if (ready > 0) return 1;
        if (ready < 0 && errno != EINTR) return -errno;
    }
}

/*
 * The local node id, as the kernel assigned it at socket creation. Read it with
 * getsockname on an *unbound* socket: this firmware's local nid is 2, not the 1
 * that Android modems use, so it cannot be assumed.
 */
static uint32_t qrtr_local_node(void) {
    int fd = socket(AF_QIPCRTR, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 0;
    struct sockaddr_qrtr self;
    socklen_t len = sizeof self;
    uint32_t node = 0;
    if (getsockname(fd, (struct sockaddr *)&self, &len) == 0) node = self.sq_node;
    close(fd);
    return node;
}

/* Ask the kernel nameserver for [service]. Returns 0 and fills [server]. */
static int lookup_with(const struct qrtr_abi *abi, uint32_t service, struct sockaddr_qrtr *server) {
    int fd = socket(AF_QIPCRTR, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;

    struct sockaddr_qrtr there = {.sq_family = AF_QIPCRTR, .sq_node = 0, .sq_port = abi->ctrl_port};
    socklen_t len = sizeof there;
    if (getsockname(fd, (struct sockaddr *)&there, &len) < 0) {
        int err = -errno;
        close(fd);
        return err;
    }
    there.sq_port = abi->ctrl_port;

    struct qrtr_ctrl_pkt req;
    memset(&req, 0, sizeof req);
    req.cmd = abi->new_lookup;
    req.server.service = service; /* instance 0 = any */
    if (sendto(fd, &req, sizeof req, 0, (struct sockaddr *)&there, sizeof there) < 0) {
        int err = -errno;
        if (getenv("QMI_DEBUG"))
            fprintf(stderr, "  %s: sendto node %u port 0x%X: %s\n", abi->name, there.sq_node, there.sq_port,
                    strerror(errno));
        close(fd);
        return err;
    }

    int rc = -ENOENT;
    int64_t deadline = now_ms() + LOOKUP_TIMEOUT_MS;
    for (;;) {
        int ready = wait_readable(fd, deadline);
        if (ready < 0) rc = ready;
        if (ready <= 0) break;
        struct qrtr_ctrl_pkt pkt;
        ssize_t n = recv(fd, &pkt, sizeof pkt, 0);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            rc = -errno;
            break;
        }
        if ((size_t)n < sizeof pkt || pkt.cmd != abi->new_server) continue;
        /* An all-zero NEW_SERVER ends the list of results. */
        if (!pkt.server.service && !pkt.server.instance && !pkt.server.node && !pkt.server.port) break;
        if (pkt.server.service == service && pkt.server.port) {
            server->sq_family = AF_QIPCRTR;
            server->sq_node = pkt.server.node;
            server->sq_port = pkt.server.port;
            rc = 0;
            break;
        }
    }
    close(fd);
    return rc;
}

static int qrtr_lookup(uint32_t service, struct sockaddr_qrtr *server) {
    int last = -ENOENT;
    for (size_t i = 0; i < sizeof ABIS / sizeof ABIS[0]; i++) {
        int rc = lookup_with(&ABIS[i], service, server);
        if (getenv("QMI_DEBUG"))
            fprintf(stderr, "lookup service 0x%02X, %s: %s\n", service, ABIS[i].name,
                    rc == 0 ? "answered" : strerror(-rc));
        if (rc == 0) {
            abi_used = ABIS[i].name;
            if (getenv("QMI_DEBUG"))
                fprintf(stderr, "  -> node %u port %u (qrtr://%u)\n", server->sq_node, server->sq_port,
                        server->sq_node);
            return 0;
        }
        last = rc;
    }
    return last;
}

static int qmi_open(uint32_t service, int timeout_ms) {
    struct sockaddr_qrtr server;
    int rc = qrtr_lookup(service, &server);
    if (rc != 0) {
        fprintf(stderr, "qrtr lookup for service 0x%02X failed: %s (local node %u, tried %zu control ABIs)\n",
                service, strerror(-rc), qrtr_local_node(), sizeof ABIS / sizeof ABIS[0]);
        return rc;
    }
    int fd = socket(AF_QIPCRTR, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    struct timeval tv = {.tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000L};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    if (connect(fd, (struct sockaddr *)&server, sizeof server) < 0) {
        int err = -errno;
        close(fd);
        return err;
    }
    return fd;
}

/* Returns the response length, or -errno. */
static ssize_t qmi_transact(int fd, uint8_t *buf, size_t len, int timeout_ms) {
    uint16_t txn = le16(buf + 1);
    uint16_t msg = le16(buf + 3);
    if (send(fd, buf, len, 0) != (ssize_t)len) return errno ? -errno : -EIO;
    int64_t deadline = now_ms() + timeout_ms;
    for (;;) {
        int ready = wait_readable(fd, deadline);
        if (ready == 0) return -ETIMEDOUT;
        if (ready < 0) return ready;
        ssize_t n = recv(fd, buf, QMI_MAX, 0);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            return -errno;
        }
        /* Indications and late answers to earlier requests share the socket. */
        if (n >= QMI_HEADER && buf[0] == QMI_TYPE_RESPONSE && le16(buf + 1) == txn && le16(buf + 3) == msg) return n;
    }
}


/* -- Shared helpers for the sampling loop ----------------------------------- */

static void put_le16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)(v >> 8);
}

static uint16_t next_txn(void) {
    static uint16_t txn = 0;
    txn = (uint16_t)((txn + 1) & 0xFFFF);
    if (!txn) txn = 1;
    return txn;
}

/* One GET on an already-connected socket. Returns the reply length or -errno. */
static ssize_t qmi_request(int fd, uint16_t msg_id, uint8_t *buf) {
    memset(buf, 0, QMI_HEADER);
    uint16_t txn = next_txn();
    buf[0] = 0x00;
    put_le16(buf + 1, txn);
    put_le16(buf + 3, msg_id);
    put_le16(buf + 5, 0);
    return qmi_transact(fd, buf, QMI_HEADER, 4000);
}

/* Split a reply into TLVs. Returns the number found; a TLV claiming to run past
 * the body ends the parse and the ones before it are kept. */
static int parse_tlvs(const uint8_t *buf, int n, const uint8_t **tlvs, int *tlv_len) {
    memset(tlvs, 0, 256 * sizeof *tlvs);
    memset(tlv_len, 0, 256 * sizeof *tlv_len);
    int count = 0;
    if (n < QMI_HEADER) return 0;
    int end = n < QMI_HEADER + (int)le16(buf + 5) ? n : QMI_HEADER + (int)le16(buf + 5);
    int pos = QMI_HEADER;
    while (pos + TLV_HEADER <= end) {
        int id = buf[pos];
        int len = le16(buf + pos + 1);
        int start = pos + TLV_HEADER;
        if (start + len > end) break;
        tlvs[id] = buf + start;
        tlv_len[id] = len;
        count++;
        pos = start + len;
    }
    return count;
}

/* -- Decoders for the fields worth reading by eye ---------------------------- */

/* QMI numbers band N into bit N-1 of a little-endian mask. */
static void print_mask_bands(const char *label, const uint8_t *mask, int bytes) {
    printf("  %s:", label);
    int any = 0;
    for (int i = 0; i < bytes * 8; i++) {
        if (mask[i / 8] & (1u << (i % 8))) {
            printf(" %d", i + 1);
            any = 1;
        }
    }
    if (!any) printf(" (none)");
    printf("\n");
}

static void print_u16_count_list(const char *label, const uint8_t *value, int len) {
    if (len < 2) return;
    int count = le16(value);
    printf("  %s: count=%d", label, count);
    for (int i = 0; i < count && 2 + (i + 1) * 2 <= len; i++) printf(" %d", le16(value + 2 + i * 2));
    printf("\n");
}

static const char *error_name(int code) {
    switch (code) {
        case 0x00: return "none";
        case 0x01: return "malformed-msg";
        case 0x03: return "internal";
        case 0x05: return "no-free-client";
        case 0x11: return "missing-arg";
        case 0x13: return "arg-too-long";
        case 0x19: return "not-supported-by-modem";
        case 0x1A: return "no-effect";
        case 0x30: return "invalid-arg";
        case 0x34: return "not-ready";
        case 0x3C: return "invalid-transition";
        case 0x4A: return "info-unavailable";
        case 0x52: return "access-denied";
        case 0x5A: return "incompatible-state";
        case 0x39: return "invalid-message-id";
        /* 71 in libqmi's enum (QMI_PROTOCOL_ERROR_INVALID_QMI_COMMAND). This is
         * what NAS answers to 0x001E (get supported messages) and to 0x015A
         * (the LTE cell-lock full-EARFCN read) on this firmware: both messages
         * are simply not implemented here. */
        case 0x47: return "invalid-qmi-command";
        case 0x5E: return "not-supported";
        default: return "other";
    }
}


/* -- watch: the flap meter ---------------------------------------------------
 *
 * One process, one NAS socket, two GETs per tick (CA 0x00AC + SYS 0x004D), so a
 * 1 Hz sample costs ~2 ms of CPU and no fork -- the whole reason this exists
 * instead of two qmicli runs. It prints a line only when something changed, plus
 * a heartbeat, so a day of monitoring is a few hundred KB rather than 10 MB.
 *
 * The timestamp is device-local "YYYY-MM-DD HH:MM:SS", the same shape the vendor
 * dialer writes, so a host-side join with Datalog Disconnected! is a string
 * compare (see scripts/flap-meter/analyze.sh).
 *
 *   watch [interval_s] [heartbeat_s] [max_seconds]
 *   defaults: 1 60 0 (0 = run until killed)
 */
#define MAX_SCC 8

struct snapshot {
    char pcc[64];
    char scc[256];
    /* Membership and activation state are DIFFERENT events and must not be
     * counted together: RRC reconfiguration adds/releases an SCell
     * (sCellToAddModList / sCellToReleaseList, A4/A2/A6), while MAC CE
     * activates/deactivates an ALREADY CONFIGURED one -- the latter toggles with
     * data activity by design and is not a fault. Mixing them made a normal
     * power-saving toggle look like the same event as a cell being released. */
    char scc_set[224];   /* B1/150/502,B5/2450/469 -- membership only */
    char scc_state[96];  /* a=activated d=deactivated x=DECONFIGURED, per member */
    char scc_cfg[96];    /* 1=configured (state 1 or 2), 0=state 0, per member */
    char cc[16];
    char endc[16];
    char nr[48];
    char all[512];
};

static void render_snapshot(const uint8_t **ca, const int *ca_len, const uint8_t **sy, const int *sy_len,
                            struct snapshot *out) {
    static const int ca_bw_khz[] = {1400, 3000, 5000, 10000, 15000, 20000};

    out->pcc[0] = out->scc[0] = out->cc[0] = out->endc[0] = out->nr[0] = 0;
    out->scc_set[0] = out->scc_state[0] = out->scc_cfg[0] = 0;
    strcpy(out->pcc, "-");
    strcpy(out->scc, "-");
    strcpy(out->endc, "?");
    strcpy(out->nr, "-");

    const uint8_t *pcc = ca[0x13];
    if (pcc && ca_len[0x13] >= 10) {
        snprintf(out->pcc, sizeof out->pcc, "B%d/%u/%u", le16(pcc + 8) - 120 + 1, le16(pcc + 2), le16(pcc));
    }
    const uint8_t *list = ca[0x15];
    int activated = 1; /* the PCC */
    if (list && ca_len[0x15] >= 1) {
        int count = list[0];
        int off = 1;
        size_t used = 0;
        int idx = 0;
        for (int i = 0; i < count && i < MAX_SCC && off + 15 <= ca_len[0x15]; i++) {
            int state = (int)le32(list + off + 10);
            if (state == 2) activated++;
            {
                size_t set_used = strlen(out->scc_set);
                size_t st_used = strlen(out->scc_state);
                if (set_used + 24 < sizeof out->scc_set && st_used + 3 < sizeof out->scc_state) {
                    snprintf(out->scc_set + set_used, sizeof out->scc_set - set_used, "%sB%d/%u/%u",
                             set_used ? "," : "", le16(list + off + 8) - 120 + 1, le16(list + off + 2),
                             le16(list + off));
                    /* 0 = DECONFIGURED is a RELEASE, not a deactivation: the
                     * enum is QMI_NAS_SCELL_STATE_{DECONFIGURED,DEACTIVATED,
                     * ACTIVATED} = {0,1,2}. Collapsing 0 into "deactivated" made
                     * a release indistinguishable from a MAC toggle. */
                    snprintf(out->scc_state + st_used, sizeof out->scc_state - st_used, "%s%c",
                             st_used ? "," : "", state == 2 ? 'a' : (state == 1 ? 'd' : 'x'));
                    {
                        size_t cfg_used = strlen(out->scc_cfg);
                        snprintf(out->scc_cfg + cfg_used, sizeof out->scc_cfg - cfg_used, "%s%c",
                                 cfg_used ? "," : "", state == 0 ? '0' : '1');
                    }
                }
            }
            if (idx++ == 0) {
                used += (size_t)snprintf(out->scc + used, sizeof out->scc - used, "B%d/%u/%u:%s",
                                         le16(list + off + 8) - 120 + 1, le16(list + off + 2), le16(list + off),
                                         state == 2 ? "act" : (state == 1 ? "deact" : "decfg"));
            } else {
                used += (size_t)snprintf(out->scc + used, sizeof out->scc - used, ",B%d/%u/%u:%s",
                                         le16(list + off + 8) - 120 + 1, le16(list + off + 2), le16(list + off),
                                         state == 2 ? "act" : (state == 1 ? "deact" : "decfg"));
            }
            (void)ca_bw_khz;
            off += 15;
        }
    }
    snprintf(out->cc, sizeof out->cc, "%d", activated);

    if (sy[0x4E] && sy_len[0x4E] >= 1) snprintf(out->endc, sizeof out->endc, "%d", sy[0x4E][0]);
    if (sy[0x60] && sy_len[0x60] >= 4 && le32(sy[0x60]) > 0) {
        unsigned arfcn = le32(sy[0x60]);
        if (sy[0x54] && sy_len[0x54] >= 2)
            snprintf(out->nr, sizeof out->nr, "%u/%u", le16(sy[0x54]), arfcn);
        else
            snprintf(out->nr, sizeof out->nr, "-/%u", arfcn);
    }

    snprintf(out->all, sizeof out->all, "pcc=%s scc=%s cc=%s endc=%s nr=%s", out->pcc, out->scc, out->cc,
             out->endc, out->nr);
}

static volatile int watch_stop = 0;
static void watch_on_signal(int sig) {
    (void)sig;
    watch_stop = 1;
}

static void stamp(char *out, size_t n) {
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    strftime(out, n, "%Y-%m-%d %H:%M:%S", &tm);
}

static int cmd_watch(int interval, int heartbeat, int max_seconds) {
    int fd = qmi_open(QMI_SERVICE_NAS, 3000);
    if (fd < 0) return 1;

    signal(SIGINT, watch_on_signal);
    signal(SIGTERM, watch_on_signal);
    setvbuf(stdout, NULL, _IOLBF, 0);

    static uint8_t ca_buf[QMI_MAX], sy_buf[QMI_MAX];
    struct snapshot prev, cur;
    memset(&prev, 0, sizeof prev);
    int samples = 0, changes = 0;
    int64_t started = now_ms(), last_beat = now_ms();
    char t[32];

    while (!watch_stop) {
        if (max_seconds > 0 && (now_ms() - started) / 1000 >= max_seconds) break;

        ssize_t ca_n = qmi_request(fd, 0x00AC, ca_buf);
        ssize_t sy_n = qmi_request(fd, 0x004D, sy_buf);
        if (ca_n < 0 || sy_n < 0) {
            /* A dead socket is worth one line, then the loop ends: a monitor that
             * silently stops is worse than no monitor. */
            stamp(t, sizeof t);
            printf("%s ERROR read failed: %s\n", t, strerror(-(int)(ca_n < 0 ? ca_n : sy_n)));
            break;
        }
        samples++;

        const uint8_t *ca_tlv[256], *sy_tlv[256];
        int ca_len[256], sy_len[256];
        parse_tlvs(ca_buf, (int)ca_n, ca_tlv, ca_len);
        parse_tlvs(sy_buf, (int)sy_n, sy_tlv, sy_len);

        /* A response with a non-zero result is a failed read, not a state. */
        if (ca_tlv[0x02] && ca_len[0x02] >= 4 && le16(ca_tlv[0x02]) != 0) continue;

        render_snapshot(ca_tlv, ca_len, sy_tlv, sy_len, &cur);
        stamp(t, sizeof t);

        if (samples == 1) {
            printf("%s STATE %s\n", t, cur.all);
        } else if (strcmp(cur.all, prev.all) != 0) {
            changes++;
            if (strcmp(cur.pcc, prev.pcc) != 0) printf("%s CHANGE pcc %s -> %s\n", t, prev.pcc, cur.pcc);
            /* Membership first: an SCell being added/released outranks its state. */
            if (strcmp(cur.scc_set, prev.scc_set) != 0) {
                printf("%s CHANGE scc-set %s -> %s\n", t, prev.scc_set[0] ? prev.scc_set : "-",
                       cur.scc_set[0] ? cur.scc_set : "-");
            } else if (strcmp(cur.scc_cfg, prev.scc_cfg) != 0) {
                /* A carrier was configured or RELEASED without leaving the list. */
                printf("%s CHANGE scc-cfg %s -> %s\n", t, prev.scc_state, cur.scc_state);
            } else if (strcmp(cur.scc_state, prev.scc_state) != 0) {
                printf("%s CHANGE scc-state %s -> %s\n", t, prev.scc_state[0] ? prev.scc_state : "-",
                       cur.scc_state[0] ? cur.scc_state : "-");
            }
            if (strcmp(cur.endc, prev.endc) != 0) printf("%s CHANGE endc %s -> %s\n", t, prev.endc, cur.endc);
            if (strcmp(cur.nr, prev.nr) != 0) printf("%s CHANGE nr %s -> %s\n", t, prev.nr, cur.nr);
            printf("%s STATE %s\n", t, cur.all);
        } else if (heartbeat > 0 && now_ms() - last_beat >= heartbeat * 1000LL) {
            printf("%s HEARTBEAT %s\n", t, cur.all);
            last_beat = now_ms();
        }
        prev = cur;

        struct timespec ts = {.tv_sec = interval, .tv_nsec = 0};
        nanosleep(&ts, NULL);
    }

    stamp(t, sizeof t);
    printf("%s SUMMARY samples=%d changes=%d seconds=%lld\n", t, samples, changes,
           (long long)((now_ms() - started) / 1000));
    close(fd);
    return 0;
}


/* -- qmicli-compatible text, for the QManager lib's shared awk ----------------
 *
 * The lib parses qmicli's human output (that is what was captured and tested), so
 * the cheapest way to make this binary a drop-in backend is to print the SAME
 * three or four lines. One parser per value, two possible providers -- instead of
 * a second JSON shape nobody tests against the real modem.
 */
static void print_bands_line(const char *label, const uint8_t *mask, int bytes) {
    printf("\t%s: '", label);
    int any = 0;
    for (int i = 0; i < bytes * 8; i++) {
        if (mask[i / 8] & (1u << (i % 8))) {
            if (any) printf(", ");
            printf("%d", i + 1);
            any = 1;
        }
    }
    printf("'\n");
}

static void print_list_line(const char *label, const uint8_t *value, int len) {
    if (len < 2) {
        printf("\t%s: ''\n", label);
        return;
    }
    int count = le16(value);
    printf("\t%s: '", label);
    for (int i = 0; i < count && 2 + (i + 1) * 2 <= len; i++) printf("%s%d", i ? ", " : "", le16(value + 2 + i * 2));
    printf("'\n");
}

static int cmd_caps_text(void) {
    int fd = qmi_open(QMI_SERVICE_DMS, 3000);
    if (fd < 0) return 1;
    static uint8_t buf[QMI_MAX];
    ssize_t n = qmi_request(fd, 0x0045, buf);
    close(fd);
    if (n < 0) return 1;
    const uint8_t *tlvs[256];
    int tlv_len[256];
    parse_tlvs(buf, (int)n, tlvs, tlv_len);
    if (tlvs[0x02] && tlv_len[0x02] >= 4 && le16(tlvs[0x02]) != 0) return 3;
    printf("[qrtr] Device band capabilities retrieved:\n");
    if (tlvs[0x10] && tlv_len[0x10] >= 8) print_bands_line("LTE bands", tlvs[0x10], 8);
    /* The lib prefers this line (it carries bands 46/48, which the 8-byte mask
     * cannot) and only falls back to the plain one. */
    if (tlvs[0x12]) print_list_line("LTE bands (extended)", tlvs[0x12], tlv_len[0x12]);
    if (tlvs[0x13]) print_list_line("NR5G bands", tlvs[0x13], tlv_len[0x13]);
    return 0;
}

static int cmd_ssp_text(void) {
    int fd = qmi_open(QMI_SERVICE_NAS, 3000);
    if (fd < 0) return 1;
    static uint8_t buf[QMI_MAX];
    ssize_t n = qmi_request(fd, 0x0034, buf);
    close(fd);
    if (n < 0) return 1;
    const uint8_t *tlvs[256];
    int tlv_len[256];
    parse_tlvs(buf, (int)n, tlvs, tlv_len);
    if (tlvs[0x02] && tlv_len[0x02] >= 4 && le16(tlvs[0x02]) != 0) return 3;
    printf("[qrtr] Successfully got system selection preference\n");
    if (tlvs[0x15] && tlv_len[0x15] >= 8) print_bands_line("LTE band preference", tlvs[0x15], 8);
    if (tlvs[0x23] && tlv_len[0x23] >= 32) print_bands_line("LTE band preference (extended)", tlvs[0x23], 32);
    if (tlvs[0x2C] && tlv_len[0x2C] >= 8) print_bands_line("NR5G SA band preference", tlvs[0x2C], 64);
    if (tlvs[0x2D] && tlv_len[0x2D] >= 8) print_bands_line("NR5G NSA band preference", tlvs[0x2D], 64);
    return 0;
}


/* -- cells-text / signal-text: the neighbour and signal reads, qmicli-shaped ---
 *
 * qmi_read.sh's parsers were written against qmicli's text (that is what was
 * captured and tested), so this prints the same lines and the SAME awk parses
 * both. One parser per value, two possible providers -- rather than a second JSON
 * shape that no consumer has ever seen.
 *
 * Layouts, per Qualcomm's NAS IDL as read in bunnylock's Qualcomm.kt (which
 * decodes these two TLVs field by field, and whose comments record the traps):
 *   intra (0x13): u8 idle, 3B PLMN, u16 tac, u32 eci, u16 earfcn, u16 serving pci,
 *                 4B thresholds/priority, u8 count, then 10B per cell
 *   inter (0x14): u8 idle, u8 freq count, then per freq 6B header + 10B per cell
 *   cell: u16 pci, i16 rsrq, i16 rsrp, i16 rssi, i16 rx level  (all x0.1 except pci)
 *   extended EARFCNs (0x27 intra u32, 0x28 inter: u8 count + u32 each) carry the
 *   32-bit channel that the 16-bit field truncates for bands >= 66.
 */
static double tenth(int16_t v) { return (double)v / 10.0; }

static void print_cell(const uint8_t *c) {
    printf("\t\tPhysical Cell ID: '%u'\n", le16(c));
    printf("\t\tRSRQ: '%.1f' dB\n", tenth((int16_t)le16(c + 2)));
    printf("\t\tRSRP: '%.1f' dBm\n", tenth((int16_t)le16(c + 4)));
    printf("\t\tRSSI: '%.1f' dBm\n", tenth((int16_t)le16(c + 6)));
}

static int cmd_cells_text(void) {
    int fd = qmi_open(QMI_SERVICE_NAS, 3000);
    if (fd < 0) return 1;
    static uint8_t buf[QMI_MAX];
    ssize_t n = qmi_request(fd, 0x0043, buf);
    close(fd);
    if (n < 0) return 1;
    const uint8_t *tlvs[256];
    int tlv_len[256];
    parse_tlvs(buf, (int)n, tlvs, tlv_len);
    if (tlvs[0x02] && tlv_len[0x02] >= 4 && le16(tlvs[0x02]) != 0) return 3;

    const uint8_t *intra = tlvs[0x13];
    const uint8_t *inter = tlvs[0x14];
    const uint8_t *intra_ext = tlvs[0x27];
    const uint8_t *inter_ext = tlvs[0x28];
    if (!intra && !inter) return 4;

    printf("[qrtr] Successfully got cell location info\n");

    if (intra && tlv_len[0x13] >= 14) {
        uint32_t earfcn = intra_ext && tlv_len[0x27] >= 4 ? le32(intra_ext) : le16(intra + 10);
        int serving = le16(intra + 12);
        printf("Intrafrequency LTE Info\n");
        printf("\tServing Cell ID: '%d'\n", serving);
        printf("\tEUTRA Absolute RF Channel Number: '%u'\n", earfcn);
        /* 1+3+2+4+2+2 = 14, then the thresholds/priority (4 per the reference
         * decoder). If the count byte there is not a plausible cell count, try 3
         * -- firmware differs on whether the priority is part of that run or
         * separate, and a wrong offset would silently print zero cells. */
        int off = -1;
        for (int cand = 18; cand >= 17; cand--) {
            if (cand < tlv_len[0x13] && intra[cand] > 0 && intra[cand] <= 32) { off = cand; break; }
        }
        if (off > 0) {
            int count = intra[off];
            int p = off + 1;
            int printed = 0;
            for (int i = 0; i < count && p + 10 <= tlv_len[0x13]; i++, p += 10) {
                printf("\tCell [%d]:\n", printed++);
                print_cell(intra + p);
            }
        }
    }

    if (inter && tlv_len[0x14] >= 2) {
        printf("Interfrequency LTE Info\n");
        int freqs = inter[1];
        int p = 2;
        int ext_off = inter_ext && tlv_len[0x28] >= 1 ? 1 : -1;
        for (int f = 0; f < freqs && p + 6 <= tlv_len[0x14]; f++) {
            uint32_t earfcn = le16(inter + p);
            if (ext_off > 0 && ext_off + 4 <= tlv_len[0x28]) {
                earfcn = le32(inter_ext + ext_off);
                ext_off += 4;
            }
            int count = inter[p + 5];
            p += 6;
            printf("\tFrequency [%d]:\n", f);
            printf("\t\tEUTRA Absolute RF Channel Number: '%u'\n", earfcn);
            int printed = 0;
            for (int i = 0; i < count && p + 10 <= tlv_len[0x14]; i++, p += 10) {
                printf("\t\tCell [%d]:\n", printed++);
                /* one extra indent level under Frequency, as qmicli prints it */
                printf("\t\t\tPhysical Cell ID: '%u'\n", le16(inter + p));
                printf("\t\t\tRSRQ: '%.1f' dB\n", tenth((int16_t)le16(inter + p + 2)));
                printf("\t\t\tRSRP: '%.1f' dBm\n", tenth((int16_t)le16(inter + p + 4)));
                printf("\t\t\tRSSI: '%.1f' dBm\n", tenth((int16_t)le16(inter + p + 6)));
            }
        }
    }
    return 0;
}

static int cmd_signal_text(void) {
    int fd = qmi_open(QMI_SERVICE_NAS, 3000);
    if (fd < 0) return 1;
    static uint8_t buf[QMI_MAX];
    ssize_t n = qmi_request(fd, 0x004F, buf);
    close(fd);
    if (n < 0) return 1;
    const uint8_t *tlvs[256];
    int tlv_len[256];
    parse_tlvs(buf, (int)n, tlvs, tlv_len);
    if (tlvs[0x02] && tlv_len[0x02] >= 4 && le16(tlvs[0x02]) != 0) return 3;

    /* LTE (TLV 0x14 per qmi-service-nas.json "LTE Signal Strength"): i8 rssi,
     * i8 rsrq, i16 rsrp, i16 snr(x0.1). Message id is 0x004F -- 0x0051 is refused
     * by this modem with error 0x47, which is how the wrong id was found. */
    const uint8_t *lte = tlvs[0x14];
    if (!lte || tlv_len[0x14] < 6) return 4;
    printf("[qrtr] Successfully got signal info\n");
    printf("LTE:\n");
    printf("\tRSSI: '%d dBm'\n", (int8_t)lte[0]);
    printf("\tRSRQ: '%d dB'\n", (int8_t)lte[1]);
    printf("\tRSRP: '%d dBm'\n", (int16_t)le16(lte + 2));
    printf("\tSNR: '%.1f dB'\n", tenth((int16_t)le16(lte + 4)));

    /* NR5G (0x02) is not decoded: this unit reports none, and qmicli prints the
     * block with 'n/a' in that case. The library's parser maps 'n/a' to nulls,
     * so the shape stays identical -- but do NOT read this as "5G was measured
     * and was absent" on a device that has NR. */
    /* 0x8000 is the "not available" sentinel: this modem always includes TLV
     * 0x17, so presence alone does not mean 5G was measured. Printing it raw
     * produced rsrp -3276.8, which the library dutifully reported as a number. */
    const uint8_t *nr = NULL;
    if (tlvs[0x17] && tlv_len[0x17] >= 4 && (int16_t)le16(tlvs[0x17]) != (int16_t)0x8000) nr = tlvs[0x17];
    printf("5G:\n");
    if (nr) {
        /* TLV 0x17 is RSRP + SNR only; qmicli prints RSRQ as n/a for this shape,
         * so this does too rather than inventing one. */
        printf("\tRSRP: '%.1f dBm'\n", tenth((int16_t)le16(nr)));
        printf("\tSNR: '%.1f dB'\n", tenth((int16_t)le16(nr + 2)));
        printf("\tRSRQ: 'n/a'\n");
    } else {
        printf("\tRSRP: 'n/a'\n\tSNR: 'n/a'\n\tRSRQ: 'n/a'\n");
    }
    return 0;
}


/* -- reg-text: serving system, qmicli-shaped --------------------------------
 *
 * TLV layout verified against the real reply (2026-10-29):
 *   0x01 serving system: u8 reg state, u8 cs, u8 ps, u8 selected network,
 *                        u8 iface count, then u8 per interface
 *   0x12 current PLMN:   u16 mcc, u16 mnc, u8 desc len, desc bytes
 * The library's parser reads only `Registration state:` and the description
 * under `Current PLMN:`, but the rest is printed because a human reads this too,
 * and because printing less than qmicli does would hide a real difference.
 */
static const char *reg_state_name(int v) {
    switch (v) {
        case 0: return "not-registered";
        case 1: return "registered";
        case 2: return "not-registered-searching";
        case 3: return "registration-denied";
        case 4: return "unknown";
        case 5: return "registered-roaming";
        default: return "unknown";
    }
}

static const char *attach_name(int v) {
    switch (v) {
        case 1: return "attached";
        case 2: return "detached";
        default: return "unknown";
    }
}

static const char *net_name(int v) {
    switch (v) {
        case 2: return "3gpp";
        case 3: return "3gpp2";
        case 1: return "cdma-1x";
        default: return "unknown";
    }
}

/* 0x08 = lte is the value this modem reports; the others are from the IDL enum
 * and are cosmetic here (only the state and the description are parsed). */
static const char *iface_name(int v) {
    switch (v) {
        case 4: return "gsm";
        case 5: return "umts";
        case 8: return "lte";
        case 9: return "td-scdma";
        case 10: return "nr5g";
        default: return "unknown";
    }
}

static int cmd_reg_text(void) {
    int fd = qmi_open(QMI_SERVICE_NAS, 3000);
    if (fd < 0) return 1;
    static uint8_t buf[QMI_MAX];
    ssize_t n = qmi_request(fd, 0x0024, buf);
    close(fd);
    if (n < 0) return 1;
    const uint8_t *tlvs[256];
    int tlv_len[256];
    parse_tlvs(buf, (int)n, tlvs, tlv_len);
    if (tlvs[0x02] && tlv_len[0x02] >= 4 && le16(tlvs[0x02]) != 0) return 3;

    const uint8_t *ss = tlvs[0x01];
    if (!ss || tlv_len[0x01] < 4) return 4;

    printf("[qrtr] Successfully got serving system:\n");
    printf("\tRegistration state: '%s'\n", reg_state_name(ss[0]));
    printf("\tCS: '%s'\n", attach_name(ss[1]));
    printf("\tPS: '%s'\n", attach_name(ss[2]));
    printf("\tSelected network: '%s'\n", net_name(ss[3]));
    if (tlv_len[0x01] >= 5) {
        int count = ss[4];
        printf("\tRadio interfaces: '%d'\n", count);
        for (int i = 0; i < count && 5 + i < tlv_len[0x01]; i++)
            printf("\t\t[%d]: '%s'\n", i, iface_name(ss[5 + i]));
    }

    const uint8_t *plmn = tlvs[0x12];
    if (plmn && tlv_len[0x12] >= 5) {
        int mcc = le16(plmn);
        int mnc = le16(plmn + 2);
        int len = plmn[4];
        printf("\tCurrent PLMN:\n");
        printf("\t\tMCC: '%d'\n", mcc);
        printf("\t\tMNC: '%d'\n", mnc);
        if (len > 0 && 5 + len <= tlv_len[0x12]) {
            /* The description is printed ONLY from bytes the modem sent, and the
             * two characters that could break the JSON envelope the library
             * pastes it into are already stripped there. */
            printf("\t\tDescription: '");
            for (int i = 0; i < len; i++) putchar(plmn[5 + i]);
            printf("'\n");
        }
    }
    return 0;
}


/* -- sweep: which QMI services does this modem expose? -----------------------
 *
 * libqmi only knows the standard services. Qualcomm firmware sometimes carries
 * vendor services (IDs above the documented range, or extra instances) with
 * controls the standard set has no message for -- CA/SCELL among them. Before
 * reverse-engineering a firmware image, ask the modem what it actually serves:
 * the QRTR nameservice answers per service id, so this is a few hundred cheap
 * datagrams and no modem round trip.
 */
static int cmd_sweep(void) {
    int found = 0;
    for (uint32_t svc = 1; svc <= 0xFF; svc++) {
        struct sockaddr_qrtr server;
        /* Modern ABI only, so a service that is absent costs one 1.5 s deadline
         * rather than two. Most fail immediately (the nameserver answers for the
         * ids that exist); the sweep is tens of datagrams, not minutes. */
        int rc = lookup_with(&ABIS[0], svc, &server);
        if (rc == 0) {
            printf("  0x%02X  -> node %u port %u\n", svc, server.sq_node, server.sq_port);
            found++;
        }
    }
    printf("  %d service instance(s) answered\n", found);
    return found ? 0 : 1;
}


/* -- msgs <service>: what messages does a service implement? -----------------
 *
 * "Get Supported Messages" is message 0x001E on every QMI service (checked in
 * libqmi's IDL for nas/dms/wds/voice/uim). It needs no IDL knowledge for the
 * service being asked, which is exactly why it is the right probe for the vendor
 * services that libqmi has no name for.
 */
static void print_u16_list(const char *label, const uint8_t *v, int len) {
    if (len < 2) return;
    int count = v[0];
    int off = 1;
    /* Some services send a bare u16 array; detect by length. */
    if ((len - 1) / 2 != count) { count = len / 2; off = 0; }
    printf("  %s (%d):", label, count);
    for (int i = 0; i < count && off + (i + 1) * 2 <= len; i++)
        printf(" 0x%04X", le16(v + off + i * 2));
    printf("\n");
}

static int cmd_msgs(uint32_t service) {
    int fd = qmi_open(service, 3000);
    if (fd < 0) {
        printf("0x%02X: service not reachable\n", service);
        return 1;
    }
    static uint8_t buf[QMI_MAX];
    ssize_t n = qmi_request(fd, 0x001E, buf);
    close(fd);
    if (n < 0) {
        printf("0x%02X: no reply (%s)\n", service, strerror(-(int)n));
        return 1;
    }
    const uint8_t *tlvs[256];
    int tlv_len[256];
    parse_tlvs(buf, (int)n, tlvs, tlv_len);

    int result = tlvs[0x02] && tlv_len[0x02] >= 4 ? le16(tlvs[0x02]) : -1;
    int error = tlvs[0x02] && tlv_len[0x02] >= 4 ? le16(tlvs[0x02] + 2) : -1;
    printf("0x%02X: reply=%zd result=%d%s\n", service, n, result,
           result == 0 ? "" : " (refused)");
    if (result != 0) {
        printf("      error=0x%04X (%s)\n", error, error_name(error));
        return 0;
    }
    if (tlvs[0x10]) print_u16_list("messages", tlvs[0x10], tlv_len[0x10]);
    if (tlvs[0x11]) print_u16_list("tlvs", tlvs[0x11], tlv_len[0x11]);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
                "usage: %s <command>\n"
                "  ports       list QRTR node/port for DMS(0x02) and NAS(0x03)\n"
                "  sweep       ask the nameservice for every service id 0x01..0xFF\n"
                "  msgs <svc>  ask one service which messages it implements (0x001E)\n"
                "  caps        DMS 0x0045 band capabilities\n"
                "  ssp         NAS 0x0034 system selection preference\n"
                "  ca          NAS 0x00AC LTE CA info\n"
                "  cells       NAS 0x0043 cell location info\n"
                "  ltelock     NAS 0x00D7 LTE cell lock (16-bit EARFCN readback)\n"
                "  ltelockfull NAS 0x015A LTE cell lock (32-bit EARFCN readback)\n"
                "  nrlock      NAS 0x010F NR cell lock\n"
                "  rf          NAS 0x0031 RF band info\n"
                "  sys         NAS 0x004D system info (ENDC available, NR PCI/ARFCN/SCS)\n"
                "  raw <service> <msg_id> [hex payload]\n"
                "  watch [interval_s] [heartbeat_s] [max_s]  flap meter: prints only changes\n"
                "  caps-text \"Device band capabilities retrieved\"  qmicli-shaped, for qmi_read.sh\n"
                "  ssp-text  \"Successfully got system selection preference\"\n"
                "  cells-text \"Successfully got cell location info\"  neighbours, qmicli-shaped\n"
                "  signal-text \"Successfully got signal info\"       serving signal, same\n"
                "  reg-text  \"Successfully got serving system\"      registration/PLMN, same\n"
                "\n"
                "  QMI_DEBUG=1 prints the QRTR discovery steps.\n",
                argv[0]);
        return 2;
    }

    const char *cmd = argv[1];

    if (!strcmp(cmd, "caps-text")) return cmd_caps_text();
    if (!strcmp(cmd, "cells-text")) return cmd_cells_text();
    if (!strcmp(cmd, "signal-text")) return cmd_signal_text();
    if (!strcmp(cmd, "reg-text")) return cmd_reg_text();
    if (!strcmp(cmd, "ssp-text")) return cmd_ssp_text();

    if (!strcmp(cmd, "watch")) {
        int interval = argc > 2 ? atoi(argv[2]) : 1;
        int heartbeat = argc > 3 ? atoi(argv[3]) : 60;
        int max_seconds = argc > 4 ? atoi(argv[4]) : 0;
        if (interval < 1) interval = 1;
        return cmd_watch(interval, heartbeat, max_seconds);
    }

    if (!strcmp(cmd, "sweep")) return cmd_sweep();

    if (!strcmp(cmd, "msgs")) {
        if (argc < 3) {
            fprintf(stderr, "msgs needs a service id, e.g. msgs 0x42\n");
            return 2;
        }
        return cmd_msgs((uint32_t)strtoul(argv[2], NULL, 0));
    }

    if (!strcmp(cmd, "ports")) {
        uint32_t services[] = {QMI_SERVICE_DMS, QMI_SERVICE_NAS};
        for (int i = 0; i < 2; i++) {
            struct sockaddr_qrtr s;
            int rc = qrtr_lookup(services[i], &s);
            if (rc == 0)
                printf("service 0x%02X -> qrtr://%u port %u  [%s]\n", services[i], s.sq_node, s.sq_port, abi_used);
            else
                printf("service 0x%02X -> not found (%s)\n", services[i], strerror(-rc));
        }
        return 0;
    }

    uint32_t service = QMI_SERVICE_NAS;
    uint16_t msg_id;
    if (!strcmp(cmd, "caps")) {
        service = QMI_SERVICE_DMS;
        msg_id = 0x0045;
    } else if (!strcmp(cmd, "ssp")) {
        msg_id = 0x0034;
    } else if (!strcmp(cmd, "ca")) {
        msg_id = 0x00AC;
    } else if (!strcmp(cmd, "cells")) {
        msg_id = 0x0043;
    } else if (!strcmp(cmd, "ltelock")) {
        msg_id = 0x00D7;
    } else if (!strcmp(cmd, "ltelockfull")) {
        msg_id = 0x015A;
    } else if (!strcmp(cmd, "nrlock")) {
        msg_id = 0x010F;
    } else if (!strcmp(cmd, "rf")) {
        msg_id = 0x0031;
    } else if (!strcmp(cmd, "sys")) {
        msg_id = 0x004D;
    } else if (!strcmp(cmd, "raw")) {
        if (argc < 4) {
            fprintf(stderr, "raw needs a service and a message id\n");
            return 2;
        }
        service = (uint32_t)strtoul(argv[2], NULL, 0);
        msg_id = (uint16_t)strtoul(argv[3], NULL, 0);
    } else {
        fprintf(stderr, "unknown command: %s\n", cmd);
        return 2;
    }

    /* Optional hex payload for `raw`, e.g. "01 00 00" or 0100. */
    uint8_t payload[4096];
    size_t payload_len = 0;
    if (argc > 4) {
        for (const char *p = argv[4]; *p; p++) {
            if (*p == ' ' || *p == ':' || *p == ',') continue;
            char byte[3] = {p[0], p[1], 0};
            if (!byte[1]) break;
            payload[payload_len++] = (uint8_t)strtoul(byte, NULL, 16);
            p++;
        }
    }

    int fd = qmi_open(service, 3000);
    if (fd < 0) return 1;

    static uint8_t buf[QMI_MAX];
    memset(buf, 0, QMI_HEADER);
    uint16_t txn = (uint16_t)((now_ms() & 0x7FFF) | 1);
    buf[0] = 0x00; /* request */
    buf[1] = (uint8_t)(txn & 0xFF);
    buf[2] = (uint8_t)(txn >> 8);
    buf[3] = (uint8_t)(msg_id & 0xFF);
    buf[4] = (uint8_t)(msg_id >> 8);
    buf[5] = (uint8_t)(payload_len & 0xFF);
    buf[6] = (uint8_t)(payload_len >> 8);
    memcpy(buf + QMI_HEADER, payload, payload_len);

    int64_t t0 = now_ms();
    ssize_t n = qmi_transact(fd, buf, QMI_HEADER + payload_len, 4000);
    int64_t elapsed = now_ms() - t0;
    close(fd);
    if (n < 0) {
        printf("service=0x%02X msg=0x%04X transport error: %s (after %lld ms)\n", service, msg_id, strerror(-(int)n),
               (long long)elapsed);
        return 1;
    }

    int end = (int)n < QMI_HEADER + (int)le16(buf + 5) ? (int)n : QMI_HEADER + (int)le16(buf + 5);
    printf("service=0x%02X msg=0x%04X reply=%d bytes elapsed=%lld ms\n", service, msg_id, (int)n, (long long)elapsed);

    const uint8_t *tlvs[256] = {0};
    int tlv_len[256] = {0};
    int pos = QMI_HEADER;
    while (pos + TLV_HEADER <= end) {
        int id = buf[pos];
        int len = le16(buf + pos + 1);
        int start = pos + TLV_HEADER;
        if (start + len > end) {
            printf("  (tlv 0x%02X claims %d bytes, past the body -- stopping)\n", id, len);
            break;
        }
        tlvs[id] = buf + start;
        tlv_len[id] = len;
        pos = start + len;
    }

    if (tlvs[0x02] && tlv_len[0x02] >= 4) {
        int result = le16(tlvs[0x02]);
        int error = le16(tlvs[0x02] + 2);
        if (result != 0) printf("  result=%d error=0x%04X (%s)\n", result, error, error_name(error));
        if (result != 0) return 3;
        printf("  result=0 (ok)\n");
    }

    for (int id = 0; id < 256; id++) {
        if (!tlvs[id]) continue;
        printf("  tlv 0x%02X len=%-3d :", id, tlv_len[id]);
        for (int i = 0; i < tlv_len[id] && i < 48; i++) printf(" %02X", tlvs[id][i]);
        if (tlv_len[id] > 48) printf(" ...");
        printf("\n");
    }

    if (service == QMI_SERVICE_DMS && msg_id == 0x0045) {
        /* The legacy mask is not LTE-numbered: WCDMA band N is bit N+21. */
        if (tlvs[0x01]) print_mask_bands("legacy mask (raw bit+1, NOT LTE numbering)", tlvs[0x01], 8);
        if (tlvs[0x10]) print_mask_bands("lte bands", tlvs[0x10], 8);
        if (tlvs[0x12]) print_u16_count_list("lte bands (extended)", tlvs[0x12], tlv_len[0x12]);
        if (tlvs[0x13]) print_u16_count_list("nr5g bands", tlvs[0x13], tlv_len[0x13]);
    }
    if (msg_id == 0x0034) { /* SSP: the band masks the modem will actually use */
        if (tlvs[0x11]) printf("  mode preference: 0x%04X\n", le16(tlvs[0x11]));
        if (tlvs[0x15]) print_mask_bands("lte band pref", tlvs[0x15], 8);
        if (tlvs[0x23]) print_mask_bands("lte band pref (extended)", tlvs[0x23], 32);
        if (tlvs[0x28]) print_mask_bands("nr band pref", tlvs[0x28], 64);
        if (tlvs[0x2C]) print_mask_bands("nr SA band pref", tlvs[0x2C], 64);
        if (tlvs[0x2D]) print_mask_bands("nr NSA band pref", tlvs[0x2D], 64);
        /* 0x2B is the GET id for NR mode; 0x2E is its SET id and the only one
         * bunnylock lists, so reading 0x2E here printed a mask as an integer. */
        if (tlvs[0x2B] && tlv_len[0x2B] == 4) printf("  nr mode (0 SA+NSA, 1 SA off, 2 NSA off): %d\n", (int)le32(tlvs[0x2B]));
        if (tlvs[0x17]) printf("  change duration (0 until restart, 1 permanent): %d\n", tlvs[0x17][0]);
    }

    /* NAS_GET_LTE_CPHY_CA_INFO: PCC TLV 0x13, SCELL list 0x15 (or single 0x12).
     * Each carrier: u16 pci, u16 channel, u8 bandwidth enums are 4 bytes,
     * u16 band (120 = LTE band 1), then in the list form u8 state, u8 pad...
     * Layout per bunnylock Qualcomm.kt caCarrier(): pci, channel, i32 bandwidth,
     * u16 band, then i32 state, u8 cell index. */
    if (msg_id == 0x00AC) {
        static const int ca_bw_khz[] = {1400, 3000, 5000, 10000, 15000, 20000};
        const uint8_t *pcc = tlvs[0x13];
        if (pcc && tlv_len[0x13] >= 10) {
            int band = le16(pcc + 8) - 120 + 1;
            printf("  PCC: pci=%u earfcn=%u bw=%dkHz band=B%d\n", le16(pcc), le16(pcc + 2),
                   ca_bw_khz[le32(pcc + 4) < 6 ? (int)le32(pcc + 4) : 0], band);
        }
        const uint8_t *list = tlvs[0x15];
        if (list && tlv_len[0x15] >= 1) {
            int count = list[0];
            int off = 1;
            for (int i = 0; i < count && off + 15 <= tlv_len[0x15]; i++) {
                int band = le16(list + off + 8) - 120 + 1;
                int state = (int)le32(list + off + 10);
                printf("  SCC%d: pci=%u earfcn=%u bw=%dkHz band=B%d state=%s\n", i + 1, le16(list + off),
                       le16(list + off + 2), ca_bw_khz[le32(list + off + 4) < 6 ? (int)le32(list + off + 4) : 0], band,
                       state == 2 ? "activated" : "deactivated");
                off += 15;
            }
        }
    }

    /* NAS_GET_SYS_INFO: 0x4E ENDC available, 0x54 NR PCI, 0x5D NR SCS, 0x60 NR ARFCN. */
    if (msg_id == 0x004D) {
        static const int scs_khz[] = {15, 30, 60, 120, 240};
        if (tlvs[0x4E] && tlv_len[0x4E] >= 1) printf("  endc_available: %d\n", tlvs[0x4E][0]);
        if (tlvs[0x54] && tlv_len[0x54] >= 2) printf("  nr_pci: %u\n", le16(tlvs[0x54]));
        if (tlvs[0x60] && tlv_len[0x60] >= 4) printf("  nr_arfcn: %u\n", le32(tlvs[0x60]));
        if (tlvs[0x5D] && tlv_len[0x5D] >= 4) {
            int e = (int)le32(tlvs[0x5D]);
            printf("  nr_scs: %d kHz\n", e >= 0 && e < 5 ? scs_khz[e] : -1);
        }
    }
    /* Cell locks: { u8 count, [ u16 pci, u32 earfcn ] } (16-bit EARFCN on 0x00D7). */
    if (msg_id == 0x00D7 || msg_id == 0x015A) {
        const uint8_t *v = tlvs[0x10];
        int len = tlv_len[0x10];
        if (!v) {
            printf("  (no cell list TLV -- nothing to report)\n");
        } else {
            int count = v[0];
            int wide = msg_id == 0x015A;
            int step = wide ? 6 : 4;
            printf("  locked cells: count=%d%s\n", count, count ? "" : " (unlocked)");
            for (int i = 0; i < count && 1 + (i + 1) * step <= len; i++) {
                const uint8_t *c = v + 1 + i * step;
                uint16_t pci = le16(c);
                uint32_t earfcn = wide ? le32(c + 2) : le16(c + 2);
                printf("    pci=%u earfcn=%u\n", pci, earfcn);
            }
        }
    }
    return 0;
}
