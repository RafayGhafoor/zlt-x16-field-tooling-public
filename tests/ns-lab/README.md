# tests/ns-lab — the evidence behind docs/32

Two harnesses, no audio committed (the material is other people's recordings and
the files are tens of megabytes; both scripts fetch or expect their own input).

## 1. Offline model measurement — `lab.mjs`

Measures what RNNoise does to *this* device's uplink contract: 8 kHz G.711 after a
48 kHz suppression stage. It reports ΔSI-SDR against a clean reference, the noise
floor inside pauses, the speech-level change, the longest dropout inside speech,
the model's own delay, and the real-time factor — at 48 kHz **and** band-limited to
3.4 kHz, because the far end never hears anything above that.

```sh
# material: three noise beds + one clean speech recording, 90 s each, 48 kHz mono
mkdir -p /tmp/ns-lab/src && cd /tmp/ns-lab
for q in "fan noise no music" "city street traffic ambience" "cafe restaurant ambience chatter"; do
  id=$(yt-dlp "ytsearch3:$q" --get-id | head -1)
  yt-dlp -f bestaudio --download-sections "*30-120" --force-keyframes-at-cuts \
         -x --audio-format wav --postprocessor-args "-ar 48000 -ac 1" \
         -o "src/$(echo "$q" | cut -d' ' -f1).wav" "https://www.youtube.com/watch?v=$id"
done
# ... and one speech file named src/speech.wav

# the shipped build (0.1, async, 112 KB) and the 0.2 model for comparison
curl -sL https://registry.npmjs.org/@jitsi/rnnoise-wasm/-/rnnoise-wasm-0.2.1.tgz | tar xz -C /tmp/ns-lab/pkg

RNNOISE_BUILD=01 bun tests/ns-lab/lab.mjs
```

Committed results: `results-rnnoise-0.1.json` (shipped) and
`results-rnnoise-0.2.json` (the larger model the package also carries).

## 2. In-browser harness — `public/ns-bench.html`

Runs **the bytes the Calls page ships** (`public/ns/x16-ns-worklet.js` +
`rnnoise.wasm`) in a real `AudioWorklet`, through an `OfflineAudioContext`, and
prints the same measurements plus the graph's delay and CPU. `window.runRealtimeProbe()`
reports how long a realtime context needs to reach `ready` (119 ms measured), which
is why the product keeps the raw microphone on the peer until then.

It is a **bench page, not a product page**: it is copied into `out/` for a test run
and is not linked from the UI.

## What these harnesses cannot tell you

- How it sounds to the other end of a real call.
- CPU on a phone (measured here on x86 Firefox only).
- iOS Safari's AudioWorklet behaviour.
