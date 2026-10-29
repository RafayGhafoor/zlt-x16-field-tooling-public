# scripts/gnss-probe — can this unit get a GNSS fix?

Host-side, `ZLT_HOST`-parameterised, non-destructive. It starts a GNSS session
through SIMCom's own SDK demo (`/usr/bin/example_gnss`, shipped in the image),
listens for position indications, then stops the session.

```sh
./gnss-probe.sh                        # 90 s window, indication mask 127
./gnss-probe.sh --seconds 300          # a cold start needs minutes, not seconds
./gnss-probe.sh --collect /tmp/gnss.txt
```

Exit codes: `0` a position was seen · `3` the engine started but no fix in the window
· `1` ssh/transport · `2` usage.

## What it proved on this unit (2026-10-29)

```
gnss init success / addrxindmsghandle success!! / set indications success!!
gnss start success!!        <- the modem accepted a session; the whole chain works
gnss stop!!
```

…and then **no position in 60 s or 180 s**. Two reasons, both outside the software
(`docs/47` §2): `/data/localxtra.bin` did not exist, so the engine had never been
started before today and this is a cold start with no assistance; and a GNSS receiver
needs sky — an ODU is a mast-mounted CPE, not a desk.

So: **run it from the installed position with a 5-minute window before concluding
anything.** A helper that reads positions continuously (SDK client, same pattern as
`router-fix/voip-bridge/x16-audio.c`) is the production version of this probe.

## Why it drives a demo instead of QMI

The modem serves QMI LOC (service `0x10`) and our transport reaches it in 1 ms, but
this firmware implements only four LOC messages, all answering `missing-arg`
(`0x0020-0x0023`; `0x0024+` answer `0x0039` not-implemented) — measured with
`qmi-probe raw 0x10 <msg>`. The vendor drives GNSS with AT commands forwarded through
`atfwd_daemon` (`+CGPSXD`, `+QGPS`, NMEA), which is what `Sunsea_Gnss_*` wraps.

## The demo's input quirks (why the sequence looks odd)

| Input | Effect |
|---|---|
| `12` then a mask value | Set GNSS msg indications — without this the engine emits nothing |
| `1` | Start Gnss → `gnss start success!!` |
| `2` / `99` | Stop / exit |
| one extra empty line | it mixes `scanf()` and `fgets()`, so a leftover newline is read as the next answer |

Do not send AT GPS commands (`+CGPSXD`, `+QGPS`) directly: `simcom_gnss` owns the
session, and this modem hangs on innocent-looking queries (`AT+CSINR?` was killed at
12 s on 2026-10-29).
