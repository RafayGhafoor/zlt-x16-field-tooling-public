/* efscli -- minimal client for the qcom-efsd abstract-socket JSON protocol.
 *
 * The device has no Python, so the upstream tools/efsctl.py cannot run there.
 * This is the same thing in ~60 lines of C: send one JSON line, print one
 * JSON line back.
 *
 *   efscli <socket-name> '<json>'
 *   efscli qcom_efsd '{"cmd":"open"}'
 *   efscli qcom_efsd '{"cmd":"ls","path":"/nv/item_files/modem/lte/rrc/efs"}'
 *
 * READ-ONLY BY CONSTRUCTION: it only sends what you give it, and the daemon
 * refuses every mutating command unless it was started with -rw.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <abstract-socket-name> '<json>'\n", argv[0]);
        return 2;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    /* leading NUL => abstract namespace */
    sa.sun_path[0] = '\0';
    size_t nlen = strlen(argv[1]);
    if (nlen > sizeof(sa.sun_path) - 2) { fprintf(stderr, "socket name too long\n"); return 2; }
    strncpy(sa.sun_path + 1, argv[1], sizeof(sa.sun_path) - 2);

    /* Abstract sockets match on the exact byte range of the name, so the
     * length must be offsetof(sun_path) + 1 + strlen(name). Passing
     * sizeof(sa) here silently fails with ECONNREFUSED. */
    socklen_t alen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + nlen);

    if (connect(fd, (struct sockaddr *)&sa, alen) < 0) {
        perror("connect");
        return 1;
    }

    char *req = argv[2];
    size_t len = strlen(req);
    if (write(fd, req, len) != (ssize_t)len || write(fd, "\n", 1) != 1) {
        perror("write");
        return 1;
    }

    char buf[65536];
    size_t used = 0;
    for (;;) {
        ssize_t n = read(fd, buf + used, sizeof buf - used - 1);
        if (n < 0) { perror("read"); return 1; }
        if (n == 0) break;
        used += (size_t)n;
        if (memchr(buf, '\n', used)) break;
        if (used >= sizeof buf - 1) break;
    }
    buf[used] = '\0';

    fputs(buf, stdout);
    if (used && buf[used - 1] != '\n') fputc('\n', stdout);

    close(fd);
    return 0;
}
