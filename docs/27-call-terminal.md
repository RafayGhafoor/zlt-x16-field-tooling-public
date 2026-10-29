# 27 — Browser call terminal (VoLTE audio in the QManager UI)

Status: **working.** The X16 places and answers real cellular calls from a
browser: the microphone goes out on the uplink, the far end comes back through
the speakers, and call control is the modem's own (`ATD` / `ATH`+`AT+CHUP` /
`AT+CLCC`). It ships in two places in QManager — a **card on the dashboard**
(where it is actually used) and a **Calls tab** with the full panel — plus a
small HTTPS front for QManager, because the browser will not hand out a
microphone over plain HTTP.

Module: [`router-fix/voip-bridge/`](../router-fix/voip-bridge/) (`install.sh`,
binaries, the PCM tap pump). Capture of the finished page:
`docs/captures/2026-10-26-calls-page.png`.

This page supersedes the "parked" verdict in
[`22-voip-audio-bridge.md`](22-voip-audio-bridge.md) §10. That document concluded
the ODU had no audio backend because the ALSA card exposes only stub/dummy DAIs —
which is true, and remains true. What changed is that the **vendor PCM tap**
(`libolinterface` → `alsa_daemon`) does carry live call audio in both directions
when a call is actually answered, and that the earlier "`StartPlay` blocks
forever / `SendPcm` is dropped" results were artefacts of a **wrong function
signature**, not of a missing backend.

---

## 1. What actually works (measured, not inferred)

| Direction | Primitive | Evidence |
|---|---|---|
| Uplink (browser → call) | `Sunsea_Audio_PCMIO_SendPcm`, 320-sample frames at 8 kHz, paced | 20 s of a 1 kHz tone during an answered call: `ul_frames=999 ul_err=0`, every send accepted |
| Downlink (call → browser) | `PCMIO_OUTPUT_ATTR_S.output_cb`, ~20 ms chunks | same call: `dl_frames=1013`, 162 080 bytes ≈ 20.2 s of PCM, peak RMS 12 870 (speech) |
| Call control | `/bin/atcmd` `ATD…;` / `ATH` + `AT+CHUP` / `AT+CLCC` | `AT+CLCC` walked `2 → 3 → 0` on the far end answering; hang-up verified by re-reading `AT+CLCC` |

Three device behaviours, all reproduced, all now handled:

- **No call up**: `PCMIO_Open` returns 0, but after ~3 s the vendor reader thread
  times out and `SendPcm` starts returning `-1` with
  `status has changed -----> stop writing`. This is why the tap is opened *only*
  while a call is answered.
- **Abandoned client**: a helper killed with `kill -9` (or a segfault at exit)
  leaves `alsa_daemon` holding a dead PCMIO client, and every subsequent
  `PCMIO_Open` then blocks until it is killed. Only a daemon restart or a reboot
  clears it. Fixed at the source: every exit path now calls `PCMIO_Close` first,
  and the helper reports an open that never answers as exit status 7 so the
  supervisor stops reopening and says so instead of hammering the daemon.
- **`ATH` returns `OK` and does nothing.** During an active VoLTE call on this
  firmware the modem accepts `ATH`, answers `OK`, and keeps the call up — the
  far end stays connected while every indicator says it hung up. `AT+CHUP` is
  the command that actually tears it down. The bridge therefore hangs up with
  `ATH`, re-reads `AT+CLCC`, and falls back to `AT+CHUP` (up to three rounds)
  before reporting success; the log records which command did the work. This is
  also why `hangup()` no longer clears the call state itself — the earlier
  optimistic clear made the UI say "idle" while the tap (and the call) were
  still live.

## 2. Why this is not the X28 design

The X28 bridges ALSA devices (`arecord hw:0,12` / `aplay hw:0,0`). On the X16
there is no such device to bridge:

```
/sys/kernel/debug/asoc/components  →  soc:qcom,msm-stub-codec, snd-soc-dummy ×2
/proc/asound/pcm                   →  msm-stub-rx-0, msm-stub-tx-1, snd-soc-dummy-dai-3
```

So the audio leg is the vendor tap, and it speaks **8 kHz mono S16_LE**, which
led to the second departure: the bridge uses **G.711 µ-law (PCMU)**, the codec
every WebRTC client must implement. No Opus, therefore no libopus, therefore no
cgo — the bridge cross-compiles as a pure-Go static ARMv7 binary
(`CGO_ENABLED=0 GOARCH=arm GOARM=7`) and does no resampling at all. Gateway
alternatives were researched; Pion remains the measured fit for this endpoint, while
Janus AudioBridge is a future option if the room needs outgrow four peers:
[`31-webrtc-stack-research.md`](31-webrtc-stack-research.md).

```
Browser mic ──WebRTC/PCMU 8 kHz──▶ x16-webrtc ──UDP PCM──▶ x16-audio ──PCMIO──▶ alsa_daemon ──▶ VoLTE uplink
Browser spk ◀─WebRTC/PCMU 8 kHz── x16-webrtc ◀─UDP PCM── x16-audio ◀─output_cb── alsa_daemon ◀── VoLTE downlink
                                        │
                                        └── /bin/atcmd: ATD / ATH / AT+CLCC / AT+VTS
```

The C pump is 8 kHz mono both ways; the bridge's format work is µ-law encode/decode,
pinned against ffmpeg in `bridge/g711/g711_test.go` (decoder bit-exact, encoder
within one quantisation step), plus a bounded RTP reorder/frame mixer for joined
browsers (`../router-fix/voip-bridge/bridge/uplink_mixer.go`).

### Two devices on one cellular call

Each browser gets its own Pion `PeerConnection` (hard cap 4); all peers receive the
same downstream RTP track. Their mic streams do **not** write interleaved UDP
packets: each is decoded into a bounded per-peer queue, reordered by RTP sequence
number (40 ms wait, lost packets become silence), framed on a shared 20 ms clock,
and averaged when both talk at once. This keeps one phone's silence from halving
the other speaker's volume and prevents simultaneous streams from corrupting the
modem PCM pipe. A disconnected peer gets a 5 s ICE grace (a brief Wi-Fi handoff can
recover); a truly gone peer is removed and frees its mixer slot.

Host integration test `bridge/bridge_integration_test.go` negotiates two real Pion
peers against the bridge's HTTP SDP endpoint, verifies both ICE connections, sends
one downlink frame to both, sends two distinct mic frames and checks the mixed
frame, then closes one peer and verifies the other remains. The mixer unit tests
also cover out-of-order RTP, a lost packet becoming silence, 10 ms packets being
buffered into a whole phone frame (not half a frame plus half silence), muted-peer
non-attenuation, and the four-peer cap. These tests need no modem, call or public
network. Device smoke reached `peers:2` with two browser stand-ins on the LAN and
returned to `peers:0` after the 5 s ICE-disconnect grace; no cellular call was
active for that check.

### Serialize with QManager; quarantine a hung modem broker

`atcmd_daemon` serves one request at a time and has no request timeout. The bridge
formerly called `/bin/atcmd` outside QManager's `flock` on `/tmp/qmanager_at.lock`;
a `CLCC` could race `CCAINFO`/`CPIN`, interleave replies, and leave the call poller
timing out. The bridge now opens the **same lock read-only** and takes an exclusive
flock before every AT request; if it cannot get the lock before its deadline, it
fails closed without sending AT. A host test holds the lock and proves the bridge
will not invoke the AT client until it is released.

If the client itself times out *after* obtaining the lock, the bridge quarantines
further AT requests for that process lifetime instead of stacking retries onto
the vendor's no-timeout queue. The session panel exposes `at_quarantined` and the
reason. This is intentionally conservative: recovery of the vendor daemon is a
separate, documented operator action, not an automatic `killall` from a web
service.

**The quarantine was too broad, and a real call proved it (2026-10-28, second
incident).** The far end hung up; the modem kept reporting `stat=0`. The bridge
had quarantined the AT path after a CLCC timeout, so it (a) could not poll, (b)
kept the last state — `active` — on screen forever, (c) could not send `AT+CHUP`,
because the quarantine refused *every* command, and (d) kept reopening the PCMIO
tap for a call that was gone (17 restarts). The page showed a live call with a
hang-up button that could not work, while `AT+CPAS` said `+CPAS: 0` and `CLCC`
returned an empty list.

Three rules came out of it:

| Rule | Why |
|---|---|
| **Hang-up outranks the quarantine** | `ATH`, `AT+CHUP`, `ATA`, `AT+CHLD` always reach the modem, quarantined or not. Ending a call is the safety valve; refusing it left the operator stuck. |
| **A reply lifts the quarantine** | Any non-empty reply — even `ERROR` — proves the broker is alive again. The quarantine detects a *silent* broker, not a rejected verb. The poller also probes with one `CLCC` every 15 s, so a recovered broker is noticed without a service restart. |
| **Unverifiable is not `active`** | After three consecutive poll failures (≈6 s) the state becomes `unknown` ("Modem not answering"), the tap restarts pause, and the page says so. `active` is a claim, and a bridge that cannot read the modem has no claim to make. |

`/api/hangup` also stopped lying: it now returns `ok:false` with the reason when
`ATH`+`AT+CHUP` fail to clear the call after three rounds, and the dialler shows
that note instead of pretending the call ended. Shutdown is bounded (6 s watchdog)
and `zlt-webrtc.sh start` replaces a stale bridge still holding `:8443`, because a
vendor client that blocks `PCMIO_Close` used to leave the old process alive across
`systemctl restart` — the operator's only visible symptom being *nothing changes*.

On 2026-10-28 that quarantine first fired on a broker already wedged by an orphaned
CLCC client. The read-only `qcmd AT+CGMM` also failed; the isolated, previously
measured recovery in `docs/09-features.md` restarted **only** `atcmd_daemon` (not
dialer/TZApp/QCMAP). `qcmd AT+CGMM` then returned `SIMCOM_SIM8260E`/`OK`, the
dialer PID stayed the same, `rmnet_data0` remained the default route, and
`curl http://1.1.1.1` returned 301. Subsequent bridge polling reports
`AT+CLCC -> OK`, and a fresh `qcmd AT+CGMM` still succeeds. Diagnostic evidence:
[`captures/2026-10-28-call-hang-syn-diagnosis.md`](captures/2026-10-28-call-hang-syn-diagnosis.md).

## 3. The secure-context problem, and the answer to it

`navigator.mediaDevices.getUserMedia()` is refused outside a secure context.
QManager is served by busybox httpd on **:8080 with no TLS** — so a Calls page
served from QManager could dial, but could never carry a microphone.

The bridge therefore runs a second HTTPS listener (`:8444`) that
**reverse-proxies QManager** and answers `/callapi/*` itself:

| URL | What it is | Microphone? |
|---|---|---|
| `http://192.168.3.1:8080/cellular/calls/` | the tab, unchanged | **no** — the page says so and offers the secure link |
| `https://192.168.3.1:8444/cellular/calls/` | the same export, proxied; `/callapi` on the same origin | **yes** |
| `https://192.168.3.1:8443/` | the bridge's own standalone page (no login) | yes |

Same-origin `/callapi` also removes two problems a cross-origin call would have
had: no CORS, and no need for the browser to trust the device certificate from a
host it is not on.

The certificate is generated **by the bridge** (`--gen-cert`), not by openssl:
this device ships openssl 1.1.1, whose `req -x509` applies its own `v3_ca`
section on top of any requested extensions, producing a duplicate
`basicConstraints` and a `CA:TRUE` cert with no EKU — which Go and the macOS
platform verifier both reject (the latter with the unhelpful "certificate is not
standards compliant", while `curl -k` and `openssl verify` are perfectly happy).
The generated cert is an ECDSA P-256 leaf with SAN `IP:192.168.3.1, IP:127.0.0.1,
DNS:localhost`, `extendedKeyUsage=serverAuth`.

## 4. The QManager change (app layer, additive)

The X16 QManager tree (`QM_SRC`, default `/tmp/qm`) is a Next.js static export.
This feature adds one route and one nav entry — nothing existing is edited except
the sidebar array:

```
app/cellular/calls/page.tsx                  thin route, re-exports the shell
components/cellular/calls/calls.tsx          page shell (header + three cards)
components/cellular/calls/audio-card.tsx     Connect, the two level meters, blockers
components/cellular/calls/dialer-card.tsx    number, Call/Hang up, DTMF keypad
components/cellular/calls/session-card.tsx   tap state, frame counters, last AT
components/cellular/calls/shapes.ts          geometry + tone maps for this family
hooks/use-call-terminal.ts                   WebRTC peer, /callapi polling, meters
types/calls.ts                               the bridge's JSON, typed
components/app-sidebar.tsx                   one entry: { calls, /cellular/calls, call }
public/locales/{en,id,it,zh-CN,zh-TW}/        `calls` namespace + sidebar label
```

It follows the house conventions: thin route file, client shell owning the hooks,
cards with the 16 px radius / whisper shadow, `Badge` status chips **with a glyph**
(colour never carries state alone), 40 px readout rows, and the per-family
`shapes.ts` rather than importing another family's geometry. The card order is
the order a call happens in — connect, dial, then "what the device is doing
underneath" for when it is not working.

The same 31 files are versioned in this repository under
`router-fix/voip-bridge/qmanager/` (overlay + `MANIFEST.sha256` +
`apply.sh --check`), because the QManager tree they were written in is **not a git
repository** — without that, the app-layer half of this feature would exist only in
a `/tmp` directory. AGENTS.md §7 asks for device and QManager changes to be
committed "in both repos, same scope"; this overlay is the QManager side of that.

Deployment note: the export is pushed **over** the existing `/data/qmanager/www`
(not swapped), so `www/cgi-bin/` — which comes from QManager's own `scripts/` and
is not part of `out/` — is preserved. Back up first (below).

## 4b. Trusted by the browser: a local CA, not Let's Encrypt

The certificate is no longer a bare self-signed leaf. `ca.crt` / `ca.key` is a
**local root CA on the device** (ECDSA P-256, `CA:TRUE`, pathlength 0, 10 years)
and `server.crt` is a 825-day leaf it signs. The root is downloadable at
`https://<device>:8444/ca.crt`, so a phone or laptop installs it **once** and then
every page served here — QManager included — is trusted with no warning.

| Option | Verdict |
|---|---|
| Let's Encrypt, HTTP-01 | impossible: the CA must reach the device, and 192.168.3.1 is not routable from the internet |
| Let's Encrypt, DNS-01 | possible **only** if the customer owns a domain and can publish a record pointing a name at 192.168.3.1. Supported: drop that cert+key in place (no `ca.key`) and the bridge keeps it |
| sslip.io / nip.io | gives a hostname for an IP, but the zone is theirs, so no DNS-01 challenge can be written — still self-signed, still a warning |
| **local CA (chosen)** | offline, no domain, no cost; one install per client; leaf rotates without touching clients |

```sh
ssh zlt-x16-root '/data/webrtc/bin/zlt-webrtc.sh ca'      # path, download URL, SHA-256, install steps
```

The certificate is minted by the bridge, not openssl: this image's openssl 1.1.1
applies its own `v3_ca` section on top of requested extensions, producing a
duplicate `basicConstraints` and a CA cert with no EKU — rejected by Go and by
the macOS verifier ("certificate is not standards compliant") while
`openssl verify` and `curl -k` are perfectly happy with it.

Ownership is decided by **signature, not validity**: the device boots with an
unsynced clock (1970) and `x509.Verify` at that instant rejects everything as
"not yet valid", which made the bridge mislabel its own leaf as externally
provisioned. `CheckSignatureFrom` is used instead, and certificate rotation is
skipped until the clock is sane.

## 4c. Where it lives in QManager

| Surface | What | Two-way audio |
|---|---|---|
| `/dashboard/` (**header popup**) | a phone icon on the header's right edge opens an animated dialler: number plate, 3×4 keypad with letter groups, Call / Hang up / Mute (`M`), audio link, meters. The keyboard works with no field to click: digits append, `Backspace` deletes, `Enter` dials, `Esc` closes | over `https://…:8444/dashboard/` |
| `/cellular/calls/` (**tab**) | the full panel: meters, dialer with keypad, call history, recordings, contacts, and the device's audio path (tap state, frame counters, last AT) | over `https://…:8444/cellular/calls/` |

The dashboard dialler started as a full-width card, which cost a band of a
page made of *readings* for an action used for seconds at a time. It is now a
popup behind a phone icon: the icon itself carries the state (a green dot while a
call is up, a pulsing badge on an incoming one), and `useCallTerminal` is mounted
in the trigger rather than in the dialog so that dot stays truthful while the
popup is closed. The dialog is the system's own `DialogContent`, so the motion
(measured fade + zoom durations) is inherited rather than invented.

Both use one hook (`use-call-terminal.ts`). On QManager's own listener (`:8080`,
plain HTTP) the same pages still **dial and listen**: `/callapi` does not exist
there, so the hook falls back to `https://<host>:8443/api`, which the bridge
answers with permissive CORS; the WebRTC peer is opened **receive-only**, because
`getUserMedia` does not exist outside a secure context — there is no prompt to
accept, the API is simply absent. Both surfaces say that in one line and offer a
button to the HTTPS front; they do not hide the control or fake a failure.

## 4d. Mute, call states, log, recordings and contacts

Everything below is recorded and produced **by the device**, so it also covers
calls placed from the vendor app or received while no browser was open.

### Keyboard

`useDialKeys` gives both surfaces a phone pad on the keyboard — digits plus `* # +`
append, `Backspace` deletes, `Enter` dials — and `M` mutes (that one lives in the
terminal, because it depends on whether a microphone exists). The popup enables it
only while open.

The guard list is the point, not the mapping: any `input`, `textarea`, `select`,
`contenteditable` or modifier-held keystroke is left alone. Without it, typing a
contact's name on the calls page would dial a phone number, and QManager's own
searches would do the same.

### Mute

The mute button sits **beside Call and Hang up** on both surfaces, because that is
where a hand goes mid-sentence. It sets `MediaStreamTrack.enabled = false` — the
track, not the connection: the peer, the call and the downlink all continue, only
the outgoing audio becomes silence, and the uplink meter drops to zero as
confirmation. Anything heavier (closing the peer, stopping the track) would make
"mute" mean "half-hang-up".

It renders for the whole life of the link and is *disabled with a reason*
("No microphone on this connection") when the origin cannot capture one, rather
than disappearing — a control that vanishes reflows the row under the cursor
exactly when the user is reaching for it.

### Call states, including the two the modem cannot report

`AT+CLCC` gives dialing (2), ringing/alerting (3), incoming (4), active (0) and
held (1). Two states are added by the bridge:

| State | Where it comes from |
|---|---|
| **ended** | shown for 8 s after a call finishes, with the outcome (`answered`, `no_answer`, `missed`, `failed`). Both surfaces key their chip off the bridge's `call_label`, not off the raw CLCC code — the raw code has no way to say "it just ended" |
| **incoming** | CLCC stat 4, with the caller's number from the same response — the dashboard raises a full-width banner with Answer (`ATA`) and Decline, rather than only flipping a chip |

An incoming call is detected by the same poller that already runs for the tap, so
"listening for calls" costs one `AT+CLCC` every 5 s when idle (1.5 s while a call
is in flight). No extra process, no daemon, no second AT client.

### Call log

`/data/webrtc/log/calls.jsonl`, one line per finished call, written when the call
ends (so a reboot never truncates an entry): number, direction (from CLCC's
`<dir>`, so an incoming call is not guessed), start, answer, end, talk seconds and
outcome. Bounded at 500 entries and rewritten atomically. Exposed at `/api/calls`.

Talk time counts from the answer, which is why an unanswered call shows `—` rather
than a duration: "rang for 30 s" is not a conversation.

### Recordings

One **stereo WAV per answered call** at `/data/webrtc/recordings/`:

```
left  channel = the far end (PCM tap, pre-gain)
right channel = the browser microphone, AFTER gain (what the far end actually heard)
```

A mixdown cannot answer "what did they say" once both sides talk, and two files
have to be re-aligned by hand — a stereo file is playable anywhere and separable
later. The two directions arrive independently (tap callback vs RTP), so they are
buffered and interleaved on a 20 ms clock; a silent side writes silence, never
nothing, so the channels cannot drift. The WAV header is patched with the real
sizes on stop (an unpatched header claims zero bytes and players refuse it).
Retention keeps the newest 50; recording can be turned off in the page
(`POST /api/record`) or the service (`--record=false`).

### Contacts

`/data/webrtc/contacts.json`, filled by a **vCard import** or by hand. Parsing runs
on the device (`FN`/`N`/`ORG`/`TEL`/`EMAIL`, line-folding aware — an unjoined
folded `TEL` silently truncates the number), and an import merges rather than
duplicates: matching is on the **last nine digits**, so `+92 315 4308207`,
`0092-315-4308207` and `03154308207` are one person. That same rule turns history
rows and incoming calls into names.

## 4e. Handset receiver vs speakerphone

The browser now declares the call audio session as `play-and-record` when the
microphone/WebRTC link is opened. Browsers implementing the Audio Session API may
use that intent to choose a communication route (often the handset receiver on a
phone); the API is still marked limited/experimental, and it declares **intent**,
not a guaranteed hardware route. [[MDN: AudioSession.type](https://developer.mozilla.org/en-US/docs/Web/API/AudioSession/type)]

The **Handset / Speakerphone** control uses the real output-device APIs where both
`MediaDevices.selectAudioOutput()` and `HTMLMediaElement.setSinkId()` exist: the
browser's OS picker selects an exposed sink, and the remote audio element uses
that sink. Those APIs require HTTPS and permission, and not every mobile browser
exposes the handset receiver as a selectable sink. [[MDN: selectAudioOutput](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/selectAudioOutput)]
[[MDN: setSinkId](https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/setSinkId)]

So the button is present beside Mute but **disabled with a reason** when the
browser cannot select a distinct route; it does not pretend an `AudioSession`
mode change is a successful switch. This matters particularly on iOS Safari:
WebKit has a 2026 issue showing `setSinkId()` can resolve successfully without
actually switching a single-track remote WebRTC stream. [[WebKit bug 320086](https://bugs.webkit.org/show_bug.cgi?id=320086)]
Native apps can call platform `AVAudioSession` route overrides; a browser page
cannot call that native API. [[Apple: Audio Output Routes](https://developer.apple.com/documentation/audiotoolbox/audio-output-routes)]

The `play-and-record` intent is applied before microphone capture, and the route
control is offered only after the remote audio track exists. A human with an
Android/iPhone browser must verify that the phone offers both *receiver* and
*speakerphone* in its picker; no physical handset was available in this
verification session.

## 4f. What the kernel log shows during calls

`dmesg` during a call is mostly the modem PCM link being re-parameterised:

```
mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-rx
mdm_mi2s_hw_params rate = 48000, codec_dai->name=msm-stub-tx
```

Every one of those pairs is an **open of the modem audio path** — the vendor PCMIO
client opening at 48 kHz, which the vendor library then presents to us as 8 kHz. They
are not errors. They are, however, a *count of tap churn*: `grep -c "tap started"
/data/log/x16-webrtc.log` read 48 and `tap exited` 47 on 2026-10-28, because the vendor
PCMIO client exits on its own (`exit status 9`) after a read timeout. Each restart
costs an ALSA open plus this mi2s re-parameterisation — a CPU spike on a one-core box
and a small audio gap. It is the main reason a call costs more CPU than the audio path
alone suggests.

The other line worth knowing:

```
TCP: request_sock_TCP: Possible SYN flooding on port 989. Sending cookies.
```

:989 is QManager's TPWS listener, not the call path; the counters were unchanged over
30 s when this was investigated, so it is historical noise, not a live problem
(`captures/2026-10-28-call-hang-syn-diagnosis.md`).

## 5. Deploy, verify, roll back

```sh
cd router-fix/voip-bridge
./install.sh                 # build (zig + go), push, cert, unit, boot hook, verify
./install.sh --check         # verify only
./install.sh --uninstall     # stop, unwire, remove binaries (cert + logs kept)
```

The QManager half is a separate push of the rebuilt export:

```sh
D=$(date +%Y%m%d)
ssh zlt-x16-root "mkdir -p /data/zlt-backups/$D/qmanager-www &&
  tar czf /data/zlt-backups/$D/qmanager-www/www-pre-calls.tgz -C /data/qmanager/www ."
cd "$QM_SRC" && bun run build
tar czf - -C out . | ssh zlt-x16-root 'tar xzf - -C /data/qmanager/www'
```

Verification actually used:

```sh
ssh zlt-x16-root '/data/webrtc/bin/zlt-webrtc.sh verify'
# OK: :8443 standalone UI 200, :8444 QManager + /callapi 200, state JSON, hook wired
# (verify also checks that the leaf chains to the local CA and that /ca.crt is served)

# chain check from a workstation, with the CA only — no -k
curl -sk https://192.168.3.1:8444/ca.crt -o /tmp/x16-ca.crt
echo | openssl s_client -connect 192.168.3.1:8444 -CAfile /tmp/x16-ca.crt \
     -verify_ip 192.168.3.1 -brief 2>&1 | grep Verification
# Verification: OK

cd router-fix/voip-bridge/bridge
go run ./cmd/smoketest -url https://192.168.3.1:8443 -call <number> -seconds 20
# headless browser stand-in: dials, waits for answered + tap, sends a 1 kHz
# beep pattern, and reports downlink packets / peak RMS
```

`cmd/smoketest` is the browser stand-in: it performs the same offer/answer,
negotiates PCMU, and prints what came back. A green run means the device half is
sound; it does not replace a human hearing the far end.

Rollback of the QManager half:

```sh
ssh zlt-x16-root "tar xzf /data/zlt-backups/<date>/qmanager-www/www-pre-calls.tgz -C /data/qmanager/www"
```

## 6. Operating notes

- The tap is **single-client** and the vendor daemon is unforgiving: never
  `kill -9` the helper on a live call. `zlt-webrtc.sh stop` sends SIGTERM, which
  closes the tap properly.
- If audio silently stops working and the session card says the device stopped
  answering `PCMIO_Open`, the daemon is holding a dead client:
  `ssh zlt-x16-root '/data/webrtc/bin/zlt-webrtc.sh recover'` restarts
  `alsa.service` (voice-only; the data call is untouched) and refuses if a call
  is up. A reboot also clears it.
- The vendor library logs ~24 kB/s to stderr while a call is up (`<API> … is
  called!!`). Measured: 975 kB in 40 s, i.e. ~85 MB/hour into `/data`. The
  supervisor now filters that stream to the dozen messages that mean something
  and caps the file at 512 kB — a 20 s call now leaves ~340 bytes.
- Boot wiring is the `StartTZApp` hook (AGENTS.md §4), not `systemctl enable`:
  the unit exists for `systemctl restart zlt-webrtc` only.

## 6b. Post-reboot verification (current build)

The boot path was re-proven after the local CA, the file-based AT runner, the
`AT+CHUP` hang-up, the call log, the recorder and the contacts store all landed —
i.e. with the binaries that are on the device now, not the ones from the earlier
reboot:

```
uptime            2 min, no manual step
pidof x16-webrtc  2119                       (started by the StartTZApp hook)
verify            OK: :8443 UI 200, :8444 QManager + /callapi 200,
                  leaf chains to the local CA, /ca.crt 200, hook wired
CA fingerprint    8A:20:CE:…:6A:3E:8D        unchanged across the reboot
leaf sha256       a82f179c…                  unchanged  <- no re-issue
x16-webrtc sha    345c7a68b870f2b3           the deployed build, not a stale one
call log          4 entries                  survived (/data)
contacts          1                          survived (/data)
state             {"call":"","tap":false}, 0 x16-audio processes
www               8080/dashboard 200, 8080/cellular/calls 200,
                  8444/dashboard 200, 8444/cellular/calls 200
```

The certificate surviving is the part worth calling out: the device boots with an
unsynced clock (**1970** in the boot log), and an earlier version did re-judge its
own leaf at that instant. Both guards now hold — `externalCert()`/`leafGood()` use
`CheckSignatureFrom` rather than `x509.Verify`, and rotation is skipped while
`time.Now().Year() < 2024`.

**Expected noise, not a fault:** the service log fills with

```
http: TLS handshake error from <client>: remote error: tls: unknown certificate authority
```

from any browser that has not installed `/ca.crt` yet. That is the client correctly
rejecting an issuer it does not know — it stops for that client the moment the root
is trusted, and it is the reason the install step exists rather than a symptom of a
broken listener.

## 7. What is verified, and what still needs a human

Verified on hardware: keyboard entry — four `KeyboardEvent`s typed `0315` into the
  popup's number plate, `Backspace` left `031`, and on the calls page typing `987`
  with nothing focused filled the field while typing into the contacts *Name* field
  left the dialler at `987` (the field guard holds); the dashboard header carries a phone trigger that opens the
  dialler popup (Firefox: dialog with title `Calls`/`No call`, keys
  `1 2ABC 3DEF … 0+ #`, `Call`, `Hang up`, `MuteM`, `Connect audio`), and the old
  full-width calls band is gone from the dashboard's card list
  [docs/captures/2026-10-26-dialer-popup.png]; the calls-page dialer row carries **Call / Hang up / Mute**
  in Firefox, with Mute `disabled` and titled "No microphone on this connection"
  on an http (listen-only) origin; two-way call audio (both directions counted and measured),
the **ended** state (dashboard chip went `Dialing` → `Ended` after hang-up, driven by
`call_label`/`call_ended_at`/`last_outcome`), the
call log recording `no_answer` for a call that rang out (twice, and only for
calls that actually existed), a vCard import landing in the book and resolving an
existing history row to its contact name, and the three new cards rendering with
device data in Firefox (`docs/captures/2026-10-26-calls-log-recordings-contacts.png`),
automatic tap open/close around a call, hang-up **verified by re-reading
`AT+CLCC`** (and the `ATH`-is-a-no-op case reproduced, then fixed with
`AT+CHUP`), the dashboard card dialling a real call end-to-end in Firefox, the
QManager tab rendering and polling the device (real `AT+CLCC` on screen), the
insecure origin degrading to listen-only with a working "open the secure page"
action, the local CA chain verifying with `openssl s_client -CAfile` (no `-k`),
and boot survival after a reboot.

Not verified here, needs a person with a browser and a phone:

1. **The microphone prompt.** Install `https://192.168.3.1:8444/ca.crt` once,
   open `https://192.168.3.1:8444/dashboard/`, press *Connect audio* and allow the
   microphone: the "MIC" meter should move when you speak, and the far end should
   hear you. (The device→browser and browser→device legs were each proven with the
   headless client; the prompt itself needs a human.)
2. **An answered call**, to exercise the last unproven path: the recording only
   starts when the far end picks up. Every call placed from here during this work
   rang out, so the recorder is verified by unit test (a playable stereo WAV with a
   patched header) but not yet by a real conversation.
3. **Outgoing voice quality after the mixer change.** RTP reorder is covered for
   packet reordering, loss, 10 ms ptime, and two-speaker mixing; a no-call smoke
   cannot prove what the far end hears. Compare an answered call and preserve the
   audio frame/error counters.
4. **Mute**, which needs the same live microphone as above.
5. **Incoming calls**: the SIM has no provisioned number on this install
   ("No number provisioned"), so stat 4 has not been observed on this hardware —
   the banner and `ATA` path are implemented but unexercised.
6. **DTMF.** The keypad sends `AT+VTS="<digit>"`; this modem has not been shown
   to accept it. The raw response is shown in the dialer's note, so a rejection is
   visible rather than silent.
3. **Mute**, which needs the same live microphone as above.
4. **Incoming calls**: the SIM has no provisioned number on this install
   ("No number provisioned"), so stat 4 has not been observed on this hardware —
   the banner and `ATA` path use the same CLCC read and AT runner as everything
   else, but they are unexercised.
5. **DTMF.** The keypad sends `AT+VTS="<digit>"`; this modem has not been shown
   to accept it. The raw response is shown in the dialer's note, so a rejection is
   visible rather than silent.
