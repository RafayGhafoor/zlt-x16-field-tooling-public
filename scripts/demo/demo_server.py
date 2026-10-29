#!/usr/bin/env python3
"""demo_server.py — serve an exported QManager build with a fake, live-looking backend.

    python3 demo_server.py <export-dir> <port> [fixtures-dir]

Why this exists: the UI is a static export whose data comes from CGI shell scripts on
the modem. Opening `out/index.html` locally gives you a page that spins forever,
because every `/cgi-bin/...` fetch 404s. This serves the export AND answers those
fetches from captured JSON, so the real components render with real shapes.

Fixtures are REAL responses captured from the live ZLT X16 (see /tmp/fx), so the
shapes are exactly what the components expect — no hand-written mocks to drift.
Anything not in the fixtures answers a permissive `{"success": true}`.

TIMESTAMPS ARE SHIFTED, not faked: every epoch-second value in a response is moved by
the same delta (now - max), so a capture taken hours ago reads as "just now" while the
relative ages inside it — a 5-minute-old sample beside a 2-hour-old one — stay true.
Without this the whole UI renders as stale, which is a different (and wrong) demo.
"""
import json
import os
import re
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

EXPORT = sys.argv[1]
PORT = int(sys.argv[2])
FIXTURES = sys.argv[3] if len(sys.argv) > 3 else "/tmp/fx"

EPOCH_LO, EPOCH_HI = 1_000_000_000, 2_000_000_000  # plausible unix seconds, 2001–2033


def fixture_name(path: str, query: str) -> list[str]:
    """Candidate filenames for a request, most specific first.

    `at_cmd/fetch_signal_history.sh?view=cells&range=24h` prefers
    `at_cmd_fetch_signal_history.sh__cells24h.json`, then `…__24h.json`, then the
    bare path. Captures use the same sanitiser, so a new endpoint only needs a file.
    """
    rel = path.split("/cgi-bin/quecmanager/", 1)[-1].lstrip("/")
    stem = rel.replace("/", "_")
    names = []
    if query:
        q = parse_qs(query)
        bits = []
        if "view" in q:
            bits.append(q["view"][0])
        if "range" in q:
            bits.append(q["range"][0])
        if bits:
            names.append(f"{stem}__{''.join(bits)}.json")
            if "range" in q:
                names.append(f"{stem}__{q['range'][0]}.json")
    names.append(f"{stem}.json")
    return names


def shift_epochs(node, delta: int):
    """Add `delta` to every epoch-second number in a parsed JSON tree."""
    if isinstance(node, dict):
        return {k: shift_epochs(v, delta) for k, v in node.items()}
    if isinstance(node, list):
        return [shift_epochs(v, delta) for v in node]
    if isinstance(node, (int, float)) and not isinstance(node, bool):
        if EPOCH_LO <= node <= EPOCH_HI and float(node).is_integer():
            return int(node + delta)
    return node


def collect_epochs(node, out: list):
    if isinstance(node, dict):
        for v in node.values():
            collect_epochs(v, out)
    elif isinstance(node, list):
        for v in node:
            collect_epochs(v, out)
    elif isinstance(node, (int, float)) and not isinstance(node, bool):
        if EPOCH_LO <= node <= EPOCH_HI and float(node).is_integer():
            out.append(int(node))
    return out


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=EXPORT, **kw)

    # -- helpers ------------------------------------------------------------
    def _send_json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _cgi(self, path, query, method):
        # The auth gate: a demo with no login is the point.
        if path.endswith("/auth/check.sh"):
            return self._send_json(
                {"success": True, "authenticated": True, "setup_required": False}
            )
        if path.endswith("/auth/login.sh"):
            # The real CGI sets this indicator cookie; the UI only ever READS it
            # (hooks/use-auth.ts) to decide whether to confirm a session with
            # check.sh. Emitting it here is what makes "log in with any password"
            # land on the dashboard instead of bouncing back to the form.
            body = json.dumps({"success": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "qm_logged_in=1; Path=/; SameSite=Lax")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return

        for name in fixture_name(path, query):
            fp = os.path.join(FIXTURES, name)
            if not os.path.exists(fp):
                continue
            try:
                data = json.load(open(fp))
            except Exception:
                continue
            now = __import__("time").time()
            epochs = collect_epochs(data, [])
            delta = int(now - max(epochs)) if epochs else 0
            sys.stderr.write(f"[cgi] {path}{'?' + query if query else ''} -> {name} (shift {delta:+d}s)\n")
            return self._send_json(shift_epochs(data, delta))

        sys.stderr.write(f"[cgi] {path} -> (no fixture, generic)\n")
        return self._send_json({"success": True})

    # -- requests -----------------------------------------------------------
    def do_GET(self):
        parsed = urlparse(self.path)
        if "/cgi-bin/" in parsed.path:
            return self._cgi(parsed.path, parsed.query, "GET")
        return super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        if "/cgi-bin/" in parsed.path:
            return self._cgi(parsed.path, parsed.query, "POST")
        self._send_json({"success": True})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    if not os.path.isdir(os.path.join(EXPORT, "_next")):
        sys.exit(f"{EXPORT} does not look like a Next export (no _next/)")
    sys.stderr.write(f"serving {EXPORT} on http://127.0.0.1:{PORT}/  fixtures={FIXTURES}\n")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
