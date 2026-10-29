#!/usr/bin/env python3
"""Browser harness for the QManager Calls page (docs/27-call-terminal.md).

Serve the built QManager export on localhost and proxy the device's backend.

Why this exists: verifying the Calls page in a real browser needs a *secure
context*, and the device's certificate is self-signed, which Firefox refuses
before the page (and therefore DevTools) is reachable. localhost is a secure
context by definition, so this harness exercises the real microphone path with
only the origin different.

  /cgi-bin/...   -> http://<device>:8080/cgi-bin/...   (QManager's own backend)
  /callapi/...   -> https://<device>:8443/api/...      (the call bridge)
  everything     -> the static export in $ROOT
"""
import http.client
import http.server
import os
import ssl

DEVICE = os.environ.get("X16", "192.168.3.1")
WEB_PORT = int(os.environ.get("WEB_PORT", "8888"))
ROOT = os.environ.get("ROOT", "/tmp/qm/out")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

HOP = {"host", "connection", "keep-alive", "transfer-encoding", "upgrade", "content-length"}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def log_message(self, fmt, *args):
        pass

    def _forward(self, method, host, port, path, tls):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        if tls:
            conn = http.client.HTTPSConnection(host, port, context=CTX, timeout=40)
        else:
            conn = http.client.HTTPConnection(host, port, timeout=40)
        try:
            conn.request(method, path, body=body, headers=headers)
            res = conn.getresponse()
            data = res.read()
            hdrs = res.getheaders()
        except Exception as exc:  # noqa: BLE001 - surfaced to the page
            self.send_error(502, f"upstream unreachable: {exc}")
            return
        finally:
            conn.close()

        self.send_response(res.status)
        for k, v in hdrs:
            if k.lower() in HOP:
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _route(self, method):
        p = self.path
        # STATE_FILE exists because an incoming call cannot be scheduled: the only
        # way to prove the ring, the toast and the Answer/Reject bar is to replay
        # states. The file is re-read on every poll, so rewriting it walks the page
        # through idle -> incoming -> active -> ended exactly as the modem would.
        fake = os.environ.get("STATE_FILE")
        if fake and p.startswith("/callapi/state"):
            try:
                with open(fake, "rb") as fh:
                    data = fh.read()
            except OSError as exc:
                self.send_error(502, f"state file: {exc}")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if p.startswith("/callapi"):
            self._forward(method, DEVICE, 8443, p.replace("/callapi", "/api", 1), True)
        elif p.startswith("/cgi-bin"):
            self._forward(method, DEVICE, 8080, p, False)
        elif method == "GET":
            super().do_GET()
        else:
            self.send_error(404)

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")


if __name__ == "__main__":
    os.chdir(ROOT)
    bind = os.environ.get("BIND", "127.0.0.1")
    srv = http.server.ThreadingHTTPServer((bind, WEB_PORT), Handler)
    print(f"serving {ROOT} on http://{bind}:{WEB_PORT} (device {DEVICE})", flush=True)
    srv.serve_forever()

# Usage:
#   ( cd "$QM_SRC" && bun run build )
#   WEB_PORT=8888 ROOT="$QM_SRC/out" X16=192.168.3.1 python3 tests/qm_calls_harness.py
#   open http://localhost:8888/cellular/calls/          # secure context: two-way
#
# Binding a LAN address instead of loopback is how the *insecure* path is tested:
# http://<this-host>:8888 is not a secure context, exactly like :8080, so the page
# must fall back to listen-only and say so.
#   BIND=0.0.0.0 WEB_PORT=8888 python3 tests/qm_calls_harness.py
#
# localhost is a secure context, so this exercises the real getUserMedia path
# without installing the device's self-signed certificate into a browser profile.
