# 31 — Open-source WebRTC options for the X16 call terminal

Research requested while extending the X16 terminal with multi-device join and
cleaner audio. Short version: **keep Pion as the transport, and do not install a
replacement gateway on this 1-core router yet**. Pion is already the smallest
fitting open-source component; the hard, vendor-specific part is the PCMIO/AT
adapter, which Janus and Asterisk do not remove.

## Device constraints

| Constraint | Measured / documented on this X16 |
|---|---|
| CPU | ARMv7, **one core** |
| Call audio | SIMCom `libolinterface` PCMIO, 8 kHz mono S16_LE; the exposed ALSA card is stub/dummy only |
| Call control | `/bin/atcmd` → `atcmd_daemon`; one serialized vendor request channel, no daemon-side timeout |
| Network | LAN-only private address `192.168.3.1`; browser mic requires the local CA / HTTPS front |
| Expected clients | two devices in one cellular call (current bridge cap 4), not a public meeting service |

Whatever runs must either call `Sunsea_Audio_PCMIO_SendPcm` / downlink callback
itself, or speak a plain RTP/PCMU stream to the existing C pump. It must not open
an imaginary `hw:0,x` ALSA call device, and it must not issue raw AT concurrently
with QManager's `/tmp/qmanager_at.lock` clients.

## Candidates

| Candidate | What the project provides | Fit on this box |
|---|---|---|
| **Pion WebRTC** (current) | WebRTC PeerConnections, send/receive audio and direct RTP/RTCP APIs. The project identifies itself as a pure-Go WebRTC implementation and lists `arm` among supported platforms. [[1]](https://github.com/pion/webrtc) [[2]](https://pkg.go.dev/github.com/pion/webrtc/v4) | **Best current fit.** The deployed bridge is already a stripped static ARMv7 binary. The app still has to implement signaling, peer membership and the X16 PCM adapter, but the added mixer is a few hundred lines of 8 kHz PCM and is bounded at four peers. No second server or runtime dependency. |
| **Janus Gateway + AudioBridge** | Janus AudioBridge provides room join/leave, participants, mute/unmute, recording and RTP forwarding. Its documented RTP-participant mode supports PCMU, so a plain-RTP adapter could join the X16 PCM pump to a Janus room. [[3]](https://janus.conf.meetecho.com/docs/audiobridge) | **Best future option if room features grow.** It could replace our custom peer fan-out, mixer, per-participant mute and room recording. But it adds a C daemon and native dependency stack (GLib, Jansson, libconfig, libnice, OpenSSL, libsrtp; AudioBridge additionally uses libopus). [[4]](https://github.com/meetecho/janus-gateway) It still needs an X16 RTP↔PCMIO adapter and the `atcmd` call-control bridge. ARMv7 compilation, RSS, CPU, boot behaviour and no-WAN impact have not been measured on this firmware. Do not deploy it based on desktop measurements. |
| **Asterisk ARI External Media** | ARI can create an external-media channel and bridge RTP/UDP both directions in a requested codec/format (including ulaw); Asterisk transcodes the bridge's native media into that format. [[5]](https://docs.asterisk.org/Development/Reference-Information/Asterisk-Framework-and-API-Examples/External-Media-and-ARI/) | **Wrong abstraction for this modem.** ExternalMedia attaches to an Asterisk channel/bridge; the X16's cellular call is not a SIP/Asterisk channel and there is no SIP trunk. We would still have to bridge PCMIO into Asterisk *and* teach Asterisk about the modem call, adding a PBX-sized process to the single-core router without removing the custom call-control/audio adapter. Worth considering only if a SIP/PBX requirement arrives. |
| **LiveKit / mediasoup / generic SFU** | Full room signaling and media fan-out at service scale. | **Overkill and mismatched.** They do not know SIMCom PCMIO or `AT+CLCC`; the custom adapter remains. Their operating assumptions are for a general room service, not a local one-call endpoint on ARMv7/645 MB. |

## Decision

1. Keep **Pion** for browser WebRTC/DTLS/SRTP. It fits the current deployment and
   is already on the X16; no replacement has been shown to reduce the
   device-specific code.
2. Keep the **PCMIO C pump** as the modem adapter. That is the only proven
   call-audio endpoint on this hardware; stub ALSA DAIs cannot substitute.
3. For the requested two-device join, use the bounded per-peer PCMU queue and
   20 ms mixer in `../router-fix/voip-bridge/bridge/uplink_mixer.go`. The integration
   test negotiates two real Pion peers over loopback, verifies each gets the
   bridge downlink, sends both uplinks and checks they mix to one frame; no modem
   or external network is touched.
4. Re-evaluate **Janus AudioBridge** if requirements become larger conferences,
   server-managed per-participant mute/ACL, or many recordings per participant.
   First do a no-call ARMv7 prototype on an isolated test device and measure RSS,
   CPU, dependency closure and `RTP PCMU ↔ PCMIO` correctness. Only then decide
   whether replacing the small mixer is worth the native dependency footprint.
5. Do not switch to Asterisk just to obtain a mixer: its documented external
   media API still assumes an Asterisk call channel. The SIMCom modem would
   remain an out-of-band leg.

## SYN-cookie note from the same investigation

The warning points at **TCP :989, owned by QManager TPWS**, not the call bridge
(:8443/:8444). The recorded SYN warning was at kernel time 1416 s; MI2S setup
began at 8934 s. At capture, `/proc/net/netstat`'s `TCPReqQFullDoCookies` and
`SyncookiesSent` were 365, `TCPReqQFullDrop` was 0, and those counters did not
increase over 30 s; the :989 listen queue was empty. This is a historical queue
burst, not an active SYN flood correlated with the call. `tcp_syncookies=1`,
`somaxconn=4096`, `tcp_max_syn_backlog=2048`; no global sysctl is changed. See
[`captures/2026-10-28-call-hang-syn-diagnosis.md`](captures/2026-10-28-call-hang-syn-diagnosis.md).

The call hang has a separate, actionable cause: bridge AT requests previously
bypassed QManager's shared flock, so `AT+CLCC` could race `AT+CCAINFO` / `AT+CPIN`
and strand clients in the single-request `atcmd_daemon`. The bridge now takes the
same `/tmp/qmanager_at.lock`, and quarantines itself after a timed-out AT request
instead of stacking retries.

## Sources

1. [Pion WebRTC README](https://github.com/pion/webrtc)
2. [Pion WebRTC API](https://pkg.go.dev/github.com/pion/webrtc/v4)
3. [Janus AudioBridge plugin](https://janus.conf.meetecho.com/docs/audiobridge)
4. [Janus Gateway repository and dependency list](https://github.com/meetecho/janus-gateway)
5. [Asterisk ARI External Media](https://docs.asterisk.org/Development/Reference-Information/Asterisk-Framework-and-API-Examples/External-Media-and-ARI/)
