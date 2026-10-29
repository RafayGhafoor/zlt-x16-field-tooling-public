# 2026-10-28 — call hang and port-989 SYN-cookie diagnosis

Read-only capture. No firewall, sysctl, modem, dialer, QCMAP, audio daemon, or
call-state changes were made during this diagnosis.

## Kernel excerpt supplied by the user

```text
[ 1416.558471] TCP: request_sock_TCP: Possible SYN flooding on port 989. Sending cookies.  Check SNMP counters.
[ 8934.461628] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-rx
[ 8934.530913] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-tx
[ 8989.317850] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-rx
[ 8989.375099] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-tx
[ 9031.476456] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-rx
[ 9031.539625] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-tx
[ 9064.208290] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-rx
[ 9064.266507] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-tx
[ 9119.209127] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-rx
[ 9119.301176] mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-tx
[10386.359612] ADC channel pmx65_pa_therm1 EOC took 91 ms
```

## Port 989 finding

At collection, port **989 belonged to QManager's TPWS DPI proxy**, not the call
terminal:

```text
192.168.3.1:989 LISTEN 2627/tpws
```

The SYN-cookie warning's monotonic timestamp (1416 s) is over two hours before
the first MI2S setup event (8934 s), so it does not establish that SYN pressure
caused the later call-audio activity or the reported hang. The port had many LAN
connections from the browser host `192.168.3.176`, but the listener's current
queue was empty when sampled.

`/proc/net/netstat`, sampled twice 30 seconds apart:

| Counter | Both samples | Delta |
|---|---:|---:|
| `SyncookiesSent` / `TCPReqQFullDoCookies` | 365 | 0 |
| `SyncookiesRecv` | 270 | 0 |
| `SyncookiesFailed` | 908 | 0 |
| `ListenOverflows` / `ListenDrops` | 34 | 0 |
| `TCPReqQFullDrop` | 0 | 0 |

Conclusion: the warning describes a **historical burst**, not an active SYN flood
at collection. Cookies were emitted (270 cookie handshakes completed), while
`TCPReqQFullDrop` did not increase in the sample. This does *not* prove there were
no historical accept-queue drops: `ListenOverflows/ListenDrops=34` are cumulative
and are not per-port. No global `tcp_syncookies`, `somaxconn` or backlog sysctl
was changed; changing global TCP limits without a live overflow would mask
evidence and affect unrelated listeners.

A source check of the pinned upstream TPWS v72.13 shows `tpws_conn.h` defines
`BACKLOG 10` and `tpws.c` passes that to `listen()`. This is a plausible way for a
burst on :989 to trigger cookies even though `somaxconn=4096`; it is not evidence
that the call bridge caused the event (the warning at t=1416 s predates MI2S at
t=8934 s by more than two hours). A targeted TPWS fix would require rebuilding
its pinned, checksum-verified binary with a larger *per-listener* backlog and
proving its resource cost/Traffic Engine behaviour. It is not a global sysctl
change or an audio-bridge fix. That binary change remains a separately scoped
follow-up; do not disable syncookies. If the warning recurs, capture per-port
queue and counter deltas before deploying it.

The `mdm_mi2s_hw_params` messages are 48 kHz setup requests to
`msm-stub-rx/tx`, consistent with the previously documented stub-only audio
card. They do not prove audio passed through the driver; PCMIO frame counters and
the bridge call-state log are the relevant evidence.

## Call-hang evidence and fix

The bridge log had repeated `AT+CLCC failed (timeout after 5s)` while process
inspection showed concurrent `/bin/atcmd AT+CLCC` (bridge) and
`/bin/atcmd AT+CCAINFO?` (QManager) clients. QManager serializes its poller and
CGIs with `flock` on `/tmp/qmanager_at.lock`; the previous bridge called
`/bin/atcmd` directly and bypassed that shared lock. This is a credible cause of
interleaved replies and the bridge's repeated CLCC timeouts.

The deployed fix in `bridge/main.go` joins that same lock before every modem
transaction, and fails closed (does not call AT) if the lock is absent or not
acquired before the command deadline. Unit/integration tests hold the flock and
prove the bridge sends no command until it is released. If a modem request itself
times out *after* obtaining the lock, the bridge quarantines further AT requests
rather than stacking retries onto the broker's no-timeout queue.

On 2026-10-28 the broker still failed a bounded, shared-gate `qcmd AT+CGMM`. A
stale orphan `/bin/atcmd AT+CLCC` (PPid 1) was identified by exact argv and PPid
and only that read-only client was sent SIGTERM. The AT daemon remained wedged, so
the documented recovery in `docs/09-features.md` was used: kill the verified
`atcmd_daemon` PID and run `/etc/initscripts/start_atcmd_daemon start`. **No
dialer/QCMAP/TZApp restart was performed.** `qcmd AT+CGMM` then returned
`SIMCOM_SIM8260E`/`OK`; the dialer PID was unchanged, the default route remained
`rmnet_data0`, and `curl http://1.1.1.1` returned 301. Thus the isolated broker
recovery restored AT without a reboot or WAN outage. Afterward the bridge again
reported `AT+CLCC -> OK` and QManager's `qcmd AT+CGMM` remained successful. Two
independent Pion peers then connected to the X16 (`peers:2`) and the bridge removed
both after the 5 s ICE disconnect grace (`peers:0`). This was a **no-cellular-call**
test; it verifies multi-peer transport/lifecycle, not conversation quality.

Do not restart `alsa_daemon`, the dialer or QCMAP for this symptom.
