"use client";

// =============================================================================
// use-noise-suppression — RNNoise on the microphone, in the browser
// =============================================================================
// The far end of a cellular call hears whatever this microphone picks up, and the
// 8 kHz codec spends its bits on that noise. RNNoise (via the Apache-2.0
// @jitsi/rnnoise-wasm build) removes it before the encoder downsamples, using the
// exact worklet in `public/ns/x16-ns-worklet.js` — no server work, nothing on the
// X16's one core.
//
// Measured on the shipped bytes (docs/32):
//   - noise floor in pauses    -22.1 dB
//   - speech level             -1.05 dB (words are not eaten)
//   - added delay              ~30 ms (20 ms of it is the model's own lookahead)
//   - cost                     ~1 % of one core, x86
//
// THE ONE RULE THAT MATTERS HERE: never take the microphone away from a call.
// Every failure path returns the RAW track instead of throwing: no wasm, no
// worklet, 44.1 kHz context, an instantiate error, a wasm trap. Suppression is an
// improvement; audio is the product.
//
// The processed track is only handed over once the worklet says `ready`, and the
// caller keeps the raw track on the peer until then (replaceTrack). That is why a
// cold start cannot mute the first second of a call.
// =============================================================================

import { useCallback, useEffect, useRef, useState } from "react";

import { NS_STORAGE_KEY, nsPrefValue, parseNsPref } from "@/lib/ns-pref";

export type NsState = "off" | "starting" | "on" | "failed" | "unavailable";

export interface NoiseSuppression {
  /** What the operator asked for (persisted across reloads). */
  enabled: boolean;
  /** What is actually happening right now. */
  state: NsState;
  /** One sentence for the UI when state is not "on"/"off". */
  detail: string | null;
  setEnabled: (v: boolean) => void;
  /**
   * Wrap a microphone stream. Resolves with the processed stream when the worklet
   * is ready, and with the SAME stream it was given when anything goes wrong.
   */
  process: (stream: MediaStream) => Promise<MediaStream>;
  /** Tear down the audio graph. Safe to call twice; the mic stream is not stopped. */
  release: () => void;
  /**
   * Tell the graph the caller is muted, so the model sees silence rather than the
   * room and the output is muted at the source, not only at the track.
   */
  setMuted: (muted: boolean) => void;
}

const STORAGE_KEY = NS_STORAGE_KEY;
const WORKLET_URL = "/ns/x16-ns-worklet.js";
const WASM_URL = "/ns/rnnoise.wasm";
const READY_TIMEOUT_MS = 6000;
// `AudioContext.resume()` can hang forever in a frame without user activation: the
// promise simply never settles. Awaiting it unbounded is how a call ends up with a
// live-looking graph that produces no sound.
const RESUME_TIMEOUT_MS = 1500;
const NS_RATE = 48000;

// ON by default (lib/ns-pref.ts): the operator asked for it, and the failure path
// keeps the call audible rather than the microphone clean.
const readPref = (): boolean => {
  try {
    return parseNsPref(window.localStorage.getItem(STORAGE_KEY));
  } catch {
    // Private mode / storage disabled: the default still applies.
    return parseNsPref(null);
  }
};

export const useNoiseSuppression = (): NoiseSuppression => {
  // Default before localStorage is read (the effect below), so the first paint
  // agrees with the stored default instead of flashing "off".
  const [enabled, setEnabledState] = useState(parseNsPref(null));
  const [state, setState] = useState<NsState>("off");
  const [detail, setDetail] = useState<string | null>(null);

  const ctxRef = useRef<AudioContext | null>(null);
  const nodeRef = useRef<AudioWorkletNode | null>(null);
  const destRef = useRef<MediaStreamAudioDestinationNode | null>(null);
  const srcRef = useRef<MediaStreamAudioSourceNode | null>(null);
  const wasmRef = useRef<ArrayBuffer | null>(null);
  const readyRef = useRef(false);

  useEffect(() => {
    setEnabledState(readPref());
  }, []);

  const release = useCallback(() => {
    try {
      srcRef.current?.disconnect();
      nodeRef.current?.disconnect();
      destRef.current?.disconnect();
    } catch {
      // A half-built graph is not an error worth surfacing.
    }
    srcRef.current = null;
    nodeRef.current = null;
    destRef.current = null;
    readyRef.current = false;
    const ctx = ctxRef.current;
    ctxRef.current = null;
    if (ctx && ctx.state !== "closed") {
      void ctx.close();
    }
  }, []);

  useEffect(() => release, [release]);

  const setEnabled = useCallback(
    (v: boolean) => {
      setEnabledState(v);
      try {
        window.localStorage.setItem(STORAGE_KEY, nsPrefValue(v));
      } catch {
        // Private mode: the toggle still works for this session.
      }
      if (!v) {
        release();
        setState("off");
        setDetail(null);
      }
    },
    [release]
  );

  const process = useCallback(
    async (stream: MediaStream): Promise<MediaStream> => {
      if (!enabled) {
        return stream;
      }
      // AudioWorklet needs a secure context; without one the UI has already told
      // the operator to use :8444, so this is only a guard.
      if (!window.isSecureContext || typeof AudioWorkletNode === "undefined") {
        setState("unavailable");
        setDetail("noise suppression needs the HTTPS page (:8444)");
        return stream;
      }
      // Already running for this stream: hand back the existing processed track.
      if (readyRef.current && destRef.current) {
        return destRef.current.stream;
      }

      setState("starting");
      setDetail(null);
      try {
        if (!wasmRef.current) {
          const res = await fetch(WASM_URL, { cache: "force-cache" });
          if (!res.ok) {
            throw new Error(`wasm fetch: HTTP ${res.status}`);
          }
          wasmRef.current = await res.arrayBuffer();
        }

        // RNNoise is 48 kHz only. If this device will not give us that context,
        // refusing is more honest than processing at 44.1 kHz and claiming it
        // worked — the model would see a different band than it was trained on.
        const ctx = new AudioContext({ sampleRate: NS_RATE });
        ctxRef.current = ctx;
        if (Math.round(ctx.sampleRate) !== NS_RATE) {
          throw new Error(`audio context is ${ctx.sampleRate} Hz, RNNoise needs 48000`);
        }
        await ctx.audioWorklet.addModule(WORKLET_URL);

        const node = new AudioWorkletNode(ctx, "x16-ns", {
          numberOfInputs: 1,
          numberOfOutputs: 1,
          outputChannelCount: [1],
          processorOptions: { wasm: wasmRef.current },
        });
        nodeRef.current = node;

        const ready = new Promise<void>((resolve, reject) => {
          const timer = window.setTimeout(
            () => reject(new Error("the worklet did not report ready in time")),
            READY_TIMEOUT_MS
          );
          node.port.onmessage = (e: MessageEvent) => {
            const msg = e.data as { type?: string; reason?: string };
            if (msg?.type === "ready") {
              window.clearTimeout(timer);
              readyRef.current = true;
              resolve();
              return;
            }
            if (msg?.type === "error") {
              window.clearTimeout(timer);
              reject(new Error(msg.reason ?? "worklet error"));
              return;
            }
            // The worklet is alive but its output is silent while the microphone has
            // signal. This is the failure the far end experiences as "no voice", so
            // it must reach the page: the caller then puts a working microphone back
            // on the wire (use-call-terminal.rescueMic).
            if (msg?.type === "silent") {
              readyRef.current = false;
              setState("failed");
              setDetail(msg.reason ?? "the suppressor went silent");
            }
          };
        });

        const src = ctx.createMediaStreamSource(stream);
        srcRef.current = src;
        const dest = ctx.createMediaStreamDestination();
        destRef.current = dest;
        src.connect(node).connect(dest);

        await ready;

        // A suspended context produces a silent track that looks alive. Resume it
        // with a DEADLINE, and refuse if the browser will not let us run — silence
        // on the far end is the worst of all outcomes.
        if (ctx.state === "suspended") {
          await Promise.race([
            ctx.resume().catch(() => undefined),
            new Promise((resolve) => window.setTimeout(resolve, RESUME_TIMEOUT_MS)),
          ]);
        }
        if (ctx.state !== "running") {
          throw new Error(
            `audio context is ${ctx.state} — this needs a tap on the page before the call`
          );
        }

        // Mobile browsers suspend an AudioContext when the tab goes to the
        // background. Resuming on return is cheap; if it will not come back, say
        // so and let the caller put the raw microphone on the wire.
        ctx.addEventListener("statechange", () => {
          if (ctx.state === "suspended" && ctxRef.current === ctx) {
            void Promise.race([
              ctx.resume().catch(() => undefined),
              new Promise((resolve) => window.setTimeout(resolve, RESUME_TIMEOUT_MS)),
            ]).then(() => {
              if (ctx.state !== "running" && ctxRef.current === ctx) {
                setState("failed");
                setDetail("the audio context was suspended and would not resume");
              }
            });
          }
        });

        setState("on");
        setDetail(null);
        return dest.stream;
      } catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        setState("failed");
        setDetail(reason);
        // The caller restores the browser's own suppressor when it sees this, so
        // the far end is never left with the rawest possible microphone.
        release();
        // The raw microphone, not silence. The call continues.
        return stream;
      }
    },
    [enabled, release]
  );

  const setMuted = useCallback((muted: boolean) => {
    try {
      nodeRef.current?.port.postMessage({ type: muted ? "mute" : "unmute" });
    } catch {
      // A closed port means the graph is gone; the track flag alone still mutes.
    }
  }, []);

  return { enabled, state, detail, setEnabled, process, release, setMuted };
};
