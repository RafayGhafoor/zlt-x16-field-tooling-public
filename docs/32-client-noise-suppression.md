# 32 — Client-side noise suppression for the browser call terminal

**Question.** The far end of a cellular call hears whatever the browser's
microphone picks up. A desk fan, a café, an idling car, a room with a TV: the
network is narrowband (8 kHz G.711) and unforgiving, because the codec keeps the
noise and spends its bits on it. Can a **client-side** suppressor fix that, and
with which library?

**Short answer.** Yes, and it belongs in the browser, not on the router. It is now
built on branch `feat/noise-suppression` with **RNNoise** (`@jitsi/rnnoise-wasm`,
112 KB wasm) in our own AudioWorklet, and measured on real material. It is
**ON by default** (the operator's decision for this deployment), one switch on the
Calls page, and every failure path keeps the call audible.

Still unverified: a live cellular call, and CPU on the phone (all CPU numbers here
are x86; the browser bench ran in Firefox on this host).

---

## 1. Why the browser and not the X16

| Candidate site | Verdict | Why |
|---|---|---|
| Browser (before `addTrack`) | **where it goes** | The noise is *created* at the microphone. One suppressor per talker, paid for by that talker's phone. No extra hop, no extra latency on the device, and the bridge keeps its single job (PCM ↔ RTP). |
| The X16 bridge (Go) | no | One ARMv7 core already runs the PCMIO pump, the G.711/RTP path, a 4-peer uplink mixer and the QManager reverse proxy. Per-peer DNN inference on that core would trade call quality for call quality. |
| The far end | not ours | The carrier's own NS is the far end's business. |

There is a second, quieter benefit: the bridge's recording mixes the **browser
uplink** with the far end (`recorder.go`). Suppressing at the source therefore
improves the recordings too, with no change to the recorder.

## 2. The sample-rate fact that decides the architecture

Our uplink is **8 kHz PCMU** end to end (`Pion` negotiates PCMU only; the modem
tap runs at 8 kHz). The good suppressor models are not 8 kHz models:

| Engine | Native rate | Frame | Notes |
|---|---|---|---|
| RNNoise | **48 kHz only** | 10 ms = 480 samples | Trained on 48 kHz speech; feeding 8 kHz directly is not supported. |
| DeepFilterNet3 | 48 kHz | 10 ms (480) / 20 ms | Highest quality of the group; wasm build is several MB. |
| DTLN | 16 kHz | 10 ms (160) | Cheaper, narrower; quality below DFN3. |
| FastEnhancer | 48 kHz | 10.67 ms | Tiny/Base/Small checkpoints. |

This does **not** mean resampling twice. The correct placement is upstream of the
codec: the browser captures at 48 kHz, we suppress at 48 kHz, and WebRTC's own
encoder downsamples to 8 kHz on the way to Pion. The suppressor sees full-band
microphone audio (where the noise actually is) and the 8 kHz codec receives an
already-clean signal.

```
getUserMedia(48 kHz, AEC on, NS off, AGC on)
   -> MediaStreamAudioSourceNode
   -> AudioWorkletNode("rnnoise")     # 480-sample frames, float32
   -> MediaStreamAudioDestinationNode -> processed MediaStreamTrack
   -> RTCRtpSender.replaceTrack()     # no renegotiation, peer and call untouched
```

Guard rails this design needs, each of which is a real failure mode:

- **`AudioContext({ sampleRate: 48000 })` must be checked, not assumed.** Some
  desktops default to 44.1 kHz. If the context refuses 48 kHz, do not feed
  RNNoise — bypass and say so.
- **`noiseSuppression: false` on `getUserMedia` when ours is on.** Two suppressors
  in series produce musical noise and clipped consonants. Keep `echoCancellation`
  (we have no AEC of our own) and `autoGainControl` (but see §6 — AGC after NS can
  re-amplify residual noise, so this one needs measuring, not assuming).
- **`replaceTrack`, never renegotiation.** Renegotiating mid-call on a 1-core
  router's Pion is the kind of thing that drops a call.
- **Toggle = output track `enabled`, not teardown.** Mute must stay `enabled =
  false` on the processed track so the worklet keeps its filter state and unmute
  does not click.
- **Failure is a bypass, not a broken call.** Worklet load error, wasm trap, or
  no audio frames through the node for >1 s: fall back to the raw microphone
  track and surface the reason in the Audio card.

## 3. The five contenders, as they actually are

Checked with `gh` on 2026-10-28. Sizes are from the repo trees and the npm
registry, not from blog posts.

| Repo | What it is | License | Payload | Verdict |
|---|---|---|---|---|
| [`jitsi/rnnoise-wasm`](https://github.com/jitsi/rnnoise-wasm) | RNNoise 0.1/0.2 compiled to wasm; **a build repo**, not a package that does the work for you. The README says its sync build exists precisely to be used inside an `AudioWorklet` in Jitsi Meet. | Apache-2.0 (RNNoise itself: BSD-3) | `@jitsi/rnnoise-wasm@0.2.1`, 2 MB unpacked, 10 files | **Prototype this.** Smallest meaningful engine, predictable CPU, no ML runtime, 48 kHz, and we write the ~120-line worklet. |
| [`workadventure/noise-suppression`](https://github.com/workadventure/noise-suppression) | The best *design* here: an AudioWorklet node between mic and `RTCPeerConnection`, with DFN3 (48 kHz) **and** DTLN (16 kHz) plus background-noise detection. | MIT | npm 0.2.0: **148 MB unpacked**; the tree carries a 14.3 MB `df_bg.wasm`, 8.6 MB LiteRT wasm, and two TFLite DTLN models (1.4 + 2.5 MB) | **Do not ship the package.** Its shape is the reference; its ballast (a VAD dependency, a full LiteRT runtime) is not something to push over a router's UI. |
| [`Datadog/dtln-rs`](https://github.com/Datadog/dtln-rs) | DTLN as Rust → wasm/native/Node, embeddable. | MIT | 35 MB repo, same two TFLite models | **No.** 16 kHz DTLN for more integration work than either of the two above. |
| [`ryyr-ry/fastenhancer-web`](https://github.com/ryyr-ry/fastenhancer-web) | wasm-SIMD C inference + AudioWorklet, weights base64-in-JS (**no `.wasm` to serve, no COOP/COEP**), 48 kHz native. Tiny: 124 KB gzip, 0.45 ms/frame, 4.2% budget. | MIT (web); **upstream FastEnhancer model license to verify before shipping** | npm 0.1.1, 2.4 MB unpacked, React peer dep | **Challenger.** Technically the best size/latency story of the five. Counterweight: 2 stars, v0.1.1, one author — evaluate, and if adopted vendor the binary into `router-fix/voip-bridge/qmanager/overlay/` rather than depending on the package. |
| [`fallais/webrtc-apm`](https://github.com/fallais/webrtc-apm) | **Go, server-side**: AEC3 + NS + AGC1 (`webrtc-audio-processing` 2.x) + optional rnnoise, for `pion/mediadevices`. | BSD-3 | 69 KB (links the C++ libraries) | **Not client-side**, and wrong host. Its own README warns NS adds "cracks" on clean speech. Keep as a note if we ever need server-side AEC; we don't — the phone's browser does AEC today. |

The two that matter, honestly compared:

- **RNNoise** — old, small, boring, and still the reference for "does a phone call
  sound better". It will not hallucinate speech, it costs a fraction of one core,
  and its 48 kHz/10 ms contract is trivial to test.
- **FastEnhancer Tiny** — newer model, one tenth the download of anything else
  that does 48 kHz, and it avoids serving a `.wasm` at all. If it survives
  measurement on real phones it is the better product; if it does not, RNNoise is
  the safe answer and costs us ~300 KB.

DeepFilterNet3 is the quality ceiling and stays on the table only through its
**upstream** wasm build, not through the 148 MB package that wraps it.

## 4. Phases, each with a gate

| Phase | Work | Gate to pass |
|---|---|---|
| **P0 — bench, no product change** (~0.5 d) | A throwaway page (not deployed) that runs the same wasm in an AudioWorklet, plus a captured noisy reference (record 20 s on the test phone: 10 s silence + fan, 10 s speech + fan). | Numbers exist: silence RMS with NS off vs on, per-frame CPU, added latency. |
| **P1 — RNNoise behind a toggle** ✅ | `public/ns/x16-ns-worklet.js` + `hooks/use-noise-suppression.ts`; `AudioCard` gets the switch; default **Off**; localStorage remembers the choice. The raw mic stays on the peer until the worklet reports `ready`, then `replaceTrack` — a cold start cannot mute the call. | Renders and persists (verified in the browser: label, `aria-pressed`, `x16.ns.enabled=1`). **Still open:** `ul_frames` climbing during a real call, and the failure paths with a live peer. |
| **P2 — measure on hardware** | Two phones (one Android Chrome, one iOS Safari), one answered call each, far-end opinion recorded. | Silence floor improves by **≥ 10 dB**; added latency **≤ 20 ms**; **≤ 5 %** of one core at 48 kHz; no audible artifact on clean speech. |
| **P3 — default On** ⚠️ shipped before the P2 gate | The operator asked for it on by default, so `lib/ns-pref.ts` defaults to on, `"0"` is remembered as an explicit off, and a value that is not a decision falls back to the default. Compared with the plan, one gate is therefore **skipped**: no phone measurement was made first. | Mitigations, because default-on makes every failure path the *normal* path: an explicit off wins; a non-48 kHz context, a load error or a wasm trap all bypass to the raw microphone **and** the hook re-captures with the browser's own suppressor (`noiseSuppression: true`) so the far end is never left with a rawer microphone than the pre-feature default; the card says which suppressor is actually running. |
| **P4 — challenger (optional)** | Same harness with fastenhancer-web Tiny; A/B the two on the same recordings. | Tiny beats RNNoise on the P2 metrics *and* its model license is confirmed. Then adopt it and vendor the bytes. |

Rollback for every phase is the toggle plus a `git revert`: no server state, no
router payload, no firmware involvement. That is the reason this is worth doing
client-side even though it is not free.

## 4b. What was measured (2026-10-28)

Material: three real noise beds downloaded with `yt-dlp` (fan/HVAC, street traffic,
café chatter) mixed under a clean speech recording at 5/10/15 dB SNR. Reproduce with
`tests/ns-lab/lab.mjs`; raw results in `tests/ns-lab/results-rnnoise-0.1.json`.

**Suppression, at 8 kHz — the band the cellular far end actually hears** (the
model runs at 48 kHz, then G.711 keeps 300–3400 Hz; this is the number that
matters, and it is *not* smaller than the 48 kHz figure):

| Input | ΔSI-SDR @8k | Noise floor in pauses | Speech level |
|---|---|---|---|
| fan @5 dB | +7.1 dB | **−21.3 dB** | −2.0 dB |
| traffic @5 dB | +7.1 dB | −17.6 dB | −1.9 dB |
| café @5 dB | +4.1 dB | −9.9 dB | −1.9 dB |
| fan @10 dB | +5.2 dB | −17.5 dB | −0.9 dB |
| traffic @10 dB | +5.1 dB | −13.9 dB | −0.8 dB |
| café @10 dB | +3.9 dB | −10.2 dB | −0.8 dB |
| fan/traffic/café @15 dB | +2.0 … +2.6 dB | −9.3 … −13.0 dB | −0.3 … −0.4 dB |

**Cost and delay:** real-time factor 0.0098 (≈1 % of one core) on this x86 host;
model delay **10 ms** (one 480-sample frame) for the 0.1 build; speech never
dropped more than 2 dB. A synthetic 1/f noise bed loses 13.6 dB, white noise only
4.7 dB — real beds behave like the 1/f case, which is why the unit tests assert
both.

**Why the shipped model is 0.1 and not 0.2:** the package ships two builds that are
not interchangeable. The async pair (`rnnoise.js` + `rnnoise.wasm`, 112 KB) is the
0.1 model; the `*-sync.js` build inlines a **1.44 MB** 0.2 model (1.18 MB gzipped)
whose runtime ABI the async glue cannot drive — driving it with the async glue
traps with an out-of-bounds memory access. On the same material 0.2 is within
~0.5 dB of 0.1 for noise reduction while being 13x larger and 2.5x slower, so 0.1
ships. The measurement is in `tests/ns-lab/results-rnnoise-0.2.json`.

**In the browser, running the bytes we deploy** (`public/ns/*`, via
`ns-bench.html`, Firefox on this host):

| Measurement | Result |
|---|---|
| Worklet + wasm instantiate inside `AudioWorklet` (no `fetch`, bytes via `processorOptions`) | ready in **119 ms**; `addModule` 24 ms; wasm fetch 5 ms |
| Noise floor, 10 dB fan mixture, shipped worklet | **−22.1 dB** |
| Speech level, same run | −1.05 dB |
| Added delay through the full graph | 30 ms |
| CPU | ≈1 % of one core |

Two traps found the hard way and now pinned by tests: `rnnoise_process_frame`
wants **int16-scale** samples (normalised floats make it a silent no-op, −0.07 dB,
no error), and the model is **not sample-aligned** (output lags input; comparing
without aligning gave −30 dB SI-SDR for a suppressor that was working perfectly).

## 4c. Latency budget: LAN, cellular, and remote/Tailscale

The question that decides whether this feature is usable remotely is not RNNoise's
30 ms — it is the path it sits on. Measured on 2026-10-28:

| Leg | RTT (avg) |
|---|---|
| LAN client → ODU (`192.168.3.1`) | **4.1 ms** |
| ODU → internet (`8.8.8.8`, i.e. the cellular leg alone) | **101 ms** (90–109) |
| This host → VPS `hayden` (public internet, Germany) | **212 ms** |
| This host → `hayden` over **Tailscale** | **326 ms** (214–697, jittery — DERP-relayed) |

What that means for "realtime, like a WhatsApp call":

- **On the LAN** the whole chain is ~4 ms of network plus the cellular leg; adding
  30 ms of suppression is not perceptible.
- **The cellular leg itself is ~100 ms RTT**, and a VoLTE call carries its own
  codec/jitter-buffer latency on both ends. That floor exists today, without us.
- **Remotely over Tailscale, the network is the problem, not the feature.** A
  326 ms relayed RTT plus a jitter buffer is already in "walkie-talkie" territory;
  30 ms of RNNoise is ~10 % of that and changes nothing about how it feels.
  Direct internet RTT to the same VPS is 212 ms, so the relay is costing ~110 ms —
  that is a **Tailscale routing/DERP finding**, not a call-terminal finding, and it
  is where remote latency work should start (direct peering / UDP path).

Consequence for the product: suppression stays available everywhere, and the
latency section of the plan is unchanged — but remote calls need the network fixed
before any audio-processing micro-optimisation is worth discussing.

## 4d. Level control: two failures, both measured, and the rule between them

Suppression changes the level situation, so it needs its own gain policy — and the
first two attempts each failed in a way a recording caught.

**Attempt 1 — browser AGC (`autoGainControl: true`).** Recording `20261028-192436`,
microphone channel, quietest-10 % floor per second: exact digital silence for 15 s,
then −59 → −53 → **−21 dBFS in three seconds while nobody spoke**, holding there for
six seconds (82 % of the energy in 400–1000 Hz, peak −0.2 dBFS) before sagging back.
A slow AGC winding up on a quiet microphone — and suppression feeds it, because
gated pauses tell the AGC the room is even quieter. The far end hears noise.

**Attempt 2 — no AGC at all.** Recording `20261028-195238`, the operator's voice:
mic −45.6 dBFS RMS over the call and **−58.2 dBFS in the last 20 s** (median −53,
p90 −47) against a far end at −24. Too quiet to hold a conversation: a phone's raw
microphone is not a usable call level, and removing the browser's gain stage without
replacing it was a mistake.

**The rule that survives both.** `x16-ns-worklet.js` now applies a **pre-model gain**
— the level RNNoise actually expects, since it is trained on int16-scale speech —
adapted on **speech frames only**:

| | |
|---|---|
| target | −26 dBFS at the model input |
| range | 0 … +30 dB |
| step | ≤ 0.5 dB per 10 ms frame (≈ 50 dB/s while speaking) |
| gate | adapt only when RNNoise's VAD ≥ 0.5; **freeze entirely on silence** |
| ceiling | soft limiter after the model: untouched below 0.7, tanh knee to 0.98 |

Freezing instead of decaying on silence is the whole difference: the browser AGC
ramps on anything quiet, ours cannot ramp on a frame the model says is not speech.
Three assertions in `tests/ts/rnnoise.test.ts` hold that shape (VAD gate present, no
decay branch on silence, gain bounded), because it is one missing `if` away from
being lost.

## 5. What we will measure, and how

Per AGENTS.md §6 the standard is observable ground truth, not "sounds better":

1. **Silence floor (dB).** RMS of a recorded 3 s non-speech window, NS off vs on,
   from the *same* capture. Target ≥ 10 dB improvement; more than ~25 dB usually
   means speech is being eaten too.
2. **Speech preservation.** Peak/RMS of the speech windows must not drop more than
   ~2 dB, and no frame may be zeroed for > 20 ms inside a word (dropout artefact).
3. **Added latency.** Compare `AudioWorklet` `currentFrame`/`currentTime` against
   wall clock, plus one 10 ms frame for the worklet's own window. Budget ≤ 20 ms.
4. **CPU.** Wall-clock time inside `process()` summed over 10 s, divided by 10 s;
   report as % of one core. Budget ≤ 5 % on the test Android device.
5. **Call-path integrity.** `/api/state`: `ul_frames` climbing, `ul_age` absent,
   `ice` connected, no `tap_restarts` growth.
6. **Recording check.** Because the recorder mixes the browser uplink, the same
   improvement must be audible in `/data/webrtc/recordings/*.wav` — a second,
   independent observation that costs nothing.

## 6. Risks, and what would make us stop

| Risk | Mitigation | Stop signal |
|---|---|---|
| Musical noise / "underwater" speech from stacking with the browser's NS | `noiseSuppression: false` when ours is on, never both | Far end prefers the unprocessed call |
| AGC re-amplifying residual noise after suppression | Measure with AGC on and off; if it fights, request AGC off and apply fixed gain | Silence floor improvement < 6 dB with AGC on and no better with it off |
| Speech attenuation (RNNoise is known to duck quiet talkers) | Report speech-window RMS; keep the toggle | Word dropouts > 20 ms inside speech |
| Battery / heat on a phone | P2 CPU budget; frame cost is fixed per 10 ms | > 5 % of a core, or thermal throttling visible in the call |
| Model license of the challenger | Confirm upstream FastEnhancer license before shipping Tiny | Unclear or non-permissive |
| Page weight served by a 1-core router | RNNoise ~300 KB, Tiny 124 KB gzip; never the 148 MB package | First load of the Calls page grows by more than ~0.5 MB |
| Safari specifics | AudioWorklet needs HTTPS (we have it) and Safari's wasm SIMD is 16.4+; ship the non-SIMD build | Worklet fails to register on iOS → bypass, and the toggle reports unsupported |

## 7. Decision

1. **Do it client-side; do not touch the X16 bridge for this.** (Done: nothing on
   the device changed except `public/ns/*` inside the existing UI export.)
2. **Prototype RNNoise (`@jitsi/rnnoise-wasm`) in our own AudioWorklet**, behind a
   default-Off toggle, with an explicit bypass on every failure mode.
3. **Bench fastenhancer-web Tiny on the same recordings** as the only realistic
   challenger; adopt only if it wins the P2 metrics and its model license checks
   out — and vendor the bytes into the overlay if so.
4. **Do not ship** `@workadventure/noise-suppression` (148 MB, VAD + LiteRT
   ballast), `dtln-rs` (16 kHz, more work), or `webrtc-apm` (server-side, wrong
   host). Keep DeepFilterNet3 as a future option via its upstream wasm build.
5. **What is still unverified:** a live cellular call with suppression on (the
   bridge's `ul_frames`/`tap` behaviour), CPU on a real phone, and iOS Safari.
   Until P2 runs, the Audio card says exactly which suppressor is active rather
   than implying the DNN is always on.
