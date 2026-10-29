#!/usr/bin/env python3
"""Correlate upload failures with LAN, Internet, and ZLT X16 router health."""

from __future__ import annotations

import argparse
import csv
import getpass
import json
import os
import platform
import re
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


IAC = 255
DO = 253
DONT = 254
WILL = 251
WONT = 252

# Why the four vendor-binary sections at the end (added 2026-10-29, docs/38 §1, §5,
# docs/39 §4):
#   * /proc/<atcmd_daemon>/fd is the ONLY way to see the vendor bug that kills the
#     indication stream: if the /dev/smd9 read fd is gone, read_tty_thread is in its
#     `open("/dev/smd3")` retry loop (a node this firmware does not have), so URCs
#     (call state, SMS delivery, USSD) are dead while AT keeps answering.
#   * /tmp/logs/ATCMD_DAEMON.log is on tmpfs and the box reboots unasked; it carries
#     the vendor's three level-0 commands (any `AT+CFUN=`, `AT+CNETCI=38`,
#     `AT+CNWSEARCH`) — a free modem-reset/scan audit — plus every reconnect.
#   * /tmp/.sockmsg lists one entry per app: a socket means the daemon is running, a
#     1-byte file means it is not. Cheaper and more truthful than `ps`.
#   * /tmp/.tmpsock/atcmd is the CLI's fixed reply socket; a stale one after a
#     crash is why the next `atcmd` call can answer with someone else's payload.
ROUTER_COMMAND = r"""
echo '--- uptime ---'
uptime 2>/dev/null || cat /proc/uptime
echo '--- load ---'
cat /proc/loadavg 2>/dev/null
echo '--- memory ---'
grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached):' /proc/meminfo 2>/dev/null
echo '--- interfaces ---'
cat /proc/net/dev 2>/dev/null
echo '--- routes ---'
ip route 2>/dev/null || route -n 2>/dev/null
echo '--- conntrack ---'
cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null
cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null
echo '--- modem/network clues ---'
logread 2>/dev/null | grep -Ei 'wan|wwan|lte|5g|modem|disconnect|timeout|reset|oom|watchdog' | tail -n 30
dmesg 2>/dev/null | grep -Ei 'wan|wwan|lte|5g|modem|disconnect|timeout|reset|oom|watchdog|netdev' | tail -n 30
echo '--- atcmd daemon ---'
P=$(pgrep -f '^atcmd_daemon$' 2>/dev/null | head -1)
echo "atcmd_daemon pid=$P"
[ -n "$P" ] && ls -l /proc/$P/fd 2>/dev/null
echo '--- atcmd daemon log (last 25) ---'
tail -n 25 /tmp/logs/ATCMD_DAEMON.log 2>/dev/null
echo '--- sockmsg apps (socket = running, 1-byte file = not) ---'
ls -l /tmp/.sockmsg 2>/dev/null
echo '--- atcmd cli reply socket ---'
ls -l /tmp/.tmpsock 2>/dev/null
""".strip().replace("\n", "; ")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def ping_once(host: str, timeout: float) -> dict[str, Any]:
    wait_ms = max(100, int(timeout * 1000))
    if platform.system() == "Windows":
        command = ["ping", "-n", "1", "-w", str(wait_ms), host]
    else:
        command = ["ping", "-n", "-c", "1", "-W", str(wait_ms), host]

    started = time.monotonic()
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout + 1,
            check=False,
        )
        output = result.stdout + result.stderr
        match = re.search(r"time[=<]?\s*([0-9.]+)\s*ms", output, re.IGNORECASE)
        latency = float(match.group(1)) if match else None
        return {
            "ok": result.returncode == 0,
            "latency_ms": latency,
            "elapsed_ms": round((time.monotonic() - started) * 1000, 1),
            "error": "" if result.returncode == 0 else output.strip()[-300:],
        }
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {
            "ok": False,
            "latency_ms": None,
            "elapsed_ms": round((time.monotonic() - started) * 1000, 1),
            "error": str(exc),
        }


class TelnetSession:
    def __init__(self, host: str, port: int, timeout: float):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock: socket.socket | None = None

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock.settimeout(0.25)

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def send_line(self, value: str) -> None:
        if not self.sock:
            raise RuntimeError("Telnet socket is not connected")
        self.sock.sendall(value.encode("utf-8") + b"\r\n")

    def _clean_telnet(self, data: bytes) -> bytes:
        if not self.sock:
            return data
        clean = bytearray()
        index = 0
        while index < len(data):
            if data[index] != IAC:
                clean.append(data[index])
                index += 1
                continue
            if index + 2 >= len(data):
                break
            verb, option = data[index + 1], data[index + 2]
            if verb in (DO, DONT):
                self.sock.sendall(bytes((IAC, WONT, option)))
            elif verb in (WILL, WONT):
                self.sock.sendall(bytes((IAC, DONT, option)))
            index += 3
        return bytes(clean)

    def read_for(self, seconds: float) -> str:
        if not self.sock:
            raise RuntimeError("Telnet socket is not connected")
        deadline = time.monotonic() + seconds
        chunks: list[bytes] = []
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(8192)
                if not chunk:
                    break
                chunks.append(self._clean_telnet(chunk))
            except socket.timeout:
                continue
        return b"".join(chunks).decode("utf-8", errors="replace")

    def read_until(self, marker: str, seconds: float) -> str:
        deadline = time.monotonic() + seconds
        output = ""
        while time.monotonic() < deadline:
            output += self.read_for(min(0.5, max(0.05, deadline - time.monotonic())))
            if marker in output:
                return output
        raise TimeoutError(f"Router did not return marker {marker!r}")


def router_snapshot(
    host: str,
    port: int,
    username: str,
    password: str,
    timeout: float,
) -> dict[str, Any]:
    session = TelnetSession(host, port, timeout)
    marker_id = str(time.time_ns())
    marker = f"__ZLT_DONE_{marker_id}__"
    try:
        session.connect()
        banner = session.read_for(1.0)
        lower_banner = banner.lower()

        if "login:" in lower_banner or "username:" in lower_banner:
            session.send_line(username)
            password_prompt = session.read_for(1.0)
            banner += password_prompt
            if "password:" in password_prompt.lower():
                session.send_line(password)
                banner += session.read_for(1.0)
        elif "password:" in lower_banner:
            session.send_line(password)
            banner += session.read_for(1.0)

        # The complete marker is deliberately absent from the transmitted line,
        # so a terminal that echoes input cannot cause a false completion.
        session.send_line(
            f"{ROUTER_COMMAND}; printf '\\n__ZLT_DONE_%s__\\n' {marker_id}"
        )
        output = session.read_until(marker, timeout)
        output = output.split(marker, 1)[0]
        section = "--- uptime ---"
        first_section = output.find(section)
        second_section = output.find(section, first_section + len(section))
        if second_section >= 0:
            output = output[second_section:]
        return {"ok": True, "banner": banner[-1000:], "output": output[-30000:]}
    except (OSError, TimeoutError, RuntimeError) as exc:
        return {"ok": False, "error": str(exc), "banner": "", "output": ""}
    finally:
        session.close()


@dataclass
class Counters:
    router_failures: int = 0
    internet_failures: int = 0
    simultaneous_failures: int = 0
    wan_only_failures: int = 0
    high_latency_samples: int = 0
    samples: int = 0
    max_internet_latency_ms: float = 0.0


def update_counters(counters: Counters, row: dict[str, Any], high_latency_ms: float) -> None:
    counters.samples += 1
    router_ok = bool(row["router_ping_ok"])
    internet_ok = bool(row["internet_ping_ok"])
    if not router_ok:
        counters.router_failures += 1
    if not internet_ok:
        counters.internet_failures += 1
    if not router_ok and not internet_ok:
        counters.simultaneous_failures += 1
    if router_ok and not internet_ok:
        counters.wan_only_failures += 1
    latency = row["internet_latency_ms"]
    if latency is not None:
        counters.max_internet_latency_ms = max(counters.max_internet_latency_ms, latency)
        if latency >= high_latency_ms:
            counters.high_latency_samples += 1


def print_summary(counters: Counters, router_text: str, high_latency_ms: float) -> None:
    print("\n=== Likely diagnosis ===")
    if counters.samples == 0:
        print("No samples were collected.")
        return

    if counters.simultaneous_failures:
        print(
            "- The router itself became unreachable during the outage. Suspect router "
            "reboot/hang, Wi-Fi failure, power instability, or severe CPU overload."
        )
    if counters.wan_only_failures:
        print(
            "- The router stayed reachable while the Internet failed. Suspect the "
            "cellular/WAN modem, carrier uplink, NAT/conntrack exhaustion, or firmware."
        )
    if counters.high_latency_samples:
        print(
            f"- Internet latency exceeded {high_latency_ms:.0f} ms in "
            f"{counters.high_latency_samples}/{counters.samples} samples "
            f"(maximum {counters.max_internet_latency_ms:.1f} ms). This strongly "
            "suggests upload bufferbloat if packet loss starts only under upload load."
        )
    if counters.internet_failures == 0:
        print(
            "- No Internet packet loss was observed. Re-run the monitor and reproduce "
            "the upload problem for the entire failure window."
        )

    lower = router_text.lower()
    clues = {
        "out of memory": "Router log contains an out-of-memory event.",
        "oom-killer": "Router log contains an OOM-killer event.",
        "watchdog": "Router log contains a watchdog event, which may indicate a hang/reboot.",
        "modem reset": "Router log indicates a modem reset.",
        "disconnect": "Router log contains disconnect events; inspect the JSONL timestamps.",
        "nf_conntrack: table full": "Router conntrack table filled, which breaks new connections.",
    }
    for clue, message in clues.items():
        if clue in lower:
            print(f"- {message}")

    print(
        f"\nSamples: {counters.samples}; router loss: {counters.router_failures}; "
        f"Internet loss: {counters.internet_failures}"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Monitor a ZLT X16 while you reproduce an upload disconnect. "
            "Uses only Python's standard library and read-only router commands."
        )
    )
    parser.add_argument("--router", default="192.168.3.1", help="router IP")
    parser.add_argument("--internet-target", default="1.1.1.1", help="public ping target")
    parser.add_argument("--telnet-port", type=int, default=23)
    parser.add_argument("--username", default="root")
    parser.add_argument("--password", help="Telnet password; prompts if omitted")
    parser.add_argument("--duration", type=float, default=300, help="monitoring seconds")
    parser.add_argument("--interval", type=float, default=1.0, help="ping interval seconds")
    parser.add_argument(
        "--router-snapshot-interval",
        type=float,
        default=15.0,
        help="seconds between router telemetry snapshots; 0 disables Telnet",
    )
    parser.add_argument("--timeout", type=float, default=3.0)
    parser.add_argument(
        "--high-latency-ms",
        type=float,
        default=300.0,
        help="latency threshold used for bufferbloat diagnosis",
    )
    parser.add_argument(
        "--output-dir",
        default=f"zlt-diagnostic-{datetime.now().strftime('%Y%m%d-%H%M%S')}",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.duration <= 0 or args.interval <= 0:
        print("--duration and --interval must be greater than zero", file=sys.stderr)
        return 2

    password = args.password
    if args.router_snapshot_interval > 0 and password is None:
        password = getpass.getpass(
            f"Telnet password for {args.username}@{args.router} "
            "(press Enter if none): "
        )
    password = password or ""

    output_dir = Path(args.output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=False)
    csv_path = output_dir / "connectivity.csv"
    router_path = output_dir / "router.jsonl"
    metadata_path = output_dir / "metadata.json"
    metadata_path.write_text(
        json.dumps(
            {
                "started_at": utc_now(),
                "router": args.router,
                "internet_target": args.internet_target,
                "duration_seconds": args.duration,
                "interval_seconds": args.interval,
                "platform": platform.platform(),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    fields = [
        "timestamp",
        "router_ping_ok",
        "router_latency_ms",
        "internet_ping_ok",
        "internet_latency_ms",
        "router_ping_error",
        "internet_ping_error",
    ]
    counters = Counters()
    router_text = ""
    next_snapshot = 0.0
    deadline = time.monotonic() + args.duration

    print(f"Writing diagnostics to {output_dir}")
    print("Start the upload now. Press Ctrl-C after the disconnect is captured.\n")

    try:
        with csv_path.open("w", newline="", encoding="utf-8") as csv_file, router_path.open(
            "a", encoding="utf-8"
        ) as router_file:
            writer = csv.DictWriter(csv_file, fieldnames=fields)
            writer.writeheader()

            while time.monotonic() < deadline:
                iteration_started = time.monotonic()
                results: dict[str, dict[str, Any]] = {}

                def probe(name: str, host: str) -> None:
                    results[name] = ping_once(host, args.timeout)

                threads = [
                    threading.Thread(target=probe, args=("router", args.router)),
                    threading.Thread(
                        target=probe, args=("internet", args.internet_target)
                    ),
                ]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join()

                row = {
                    "timestamp": utc_now(),
                    "router_ping_ok": results["router"]["ok"],
                    "router_latency_ms": results["router"]["latency_ms"],
                    "internet_ping_ok": results["internet"]["ok"],
                    "internet_latency_ms": results["internet"]["latency_ms"],
                    "router_ping_error": results["router"]["error"],
                    "internet_ping_error": results["internet"]["error"],
                }
                writer.writerow(row)
                csv_file.flush()
                update_counters(counters, row, args.high_latency_ms)

                status = (
                    f"{row['timestamp']} router="
                    f"{row['router_latency_ms'] if row['router_ping_ok'] else 'DOWN'}ms "
                    f"internet="
                    f"{row['internet_latency_ms'] if row['internet_ping_ok'] else 'DOWN'}ms"
                )
                print(status)

                now = time.monotonic()
                if args.router_snapshot_interval > 0 and now >= next_snapshot:
                    snapshot = router_snapshot(
                        args.router,
                        args.telnet_port,
                        args.username,
                        password,
                        args.timeout,
                    )
                    snapshot["timestamp"] = utc_now()
                    router_file.write(json.dumps(snapshot) + "\n")
                    router_file.flush()
                    router_text += "\n" + snapshot.get("output", "")
                    router_text = router_text[-100000:]
                    next_snapshot = now + args.router_snapshot_interval

                sleep_for = args.interval - (time.monotonic() - iteration_started)
                if sleep_for > 0:
                    time.sleep(sleep_for)
    except KeyboardInterrupt:
        print("\nMonitoring stopped.")

    print_summary(counters, router_text, args.high_latency_ms)
    print(f"\nDetailed evidence: {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
