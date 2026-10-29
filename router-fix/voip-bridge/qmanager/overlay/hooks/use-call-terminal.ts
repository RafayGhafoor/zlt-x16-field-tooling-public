"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";

import { useNoiseSuppression } from "@/hooks/use-noise-suppression";
import type { NsState } from "@/hooks/use-noise-suppression";
import {
  ANSWER_BEEP,
  END_BEEP,
  RING_BEEPS_MS,
  RING_BEEP_MS,
  RING_CYCLE_MS,
  RING_GAIN,
  RING_RAMP_S,
  RING_VIBRATE_MS,
} from "@/lib/ring";
import { useTranslation } from "react-i18next";

import { displayName } from "@/lib/phone";
import type {
  CallActionResponse,
  CallLogResponse,
  CallRecord,
  CallTerminalState,
  Contact,
  GainResponse,
  RecordingInfo,
  VcfImportResult,
} from "@/types/calls";

// =============================================================================
// useCallTerminal — call state, the WebRTC link, and the two level meters
// =============================================================================
// Three independent things live here and they are deliberately kept apart:
//
//   CALL   modem state, owned by the device. Read with a 1 s poll; the page never
//          infers it from anything else.
//   LINK   a WebRTC peer between this browser and the bridge. Lifetime is the
//          user's: Connect / Disconnect.
//   MIC    whether this origin may capture audio at all.
//
// -----------------------------------------------------------------------------
// MIC IS A PROPERTY OF THE ORIGIN, NOT A PERMISSION THE USER CAN GRANT
// -----------------------------------------------------------------------------
// `getUserMedia` does not exist outside a secure context, so on
// http://192.168.3.1:8080 no prompt is ever shown and no setting changes that —
// the API itself is absent. Two consequences shape this hook:
//
//   * the link is still opened there, as a RECEIVE-ONLY peer, so the dashboard
//     can dial and you can *listen* to the far end over plain HTTP;
//   * `speak` reports false and the UI says to reopen the page on
//     https://<host>:8444, which the bridge serves with a local-CA certificate
//     (install /ca.crt once) — same export, same origin as /callapi, and a real
//     microphone.
//
// -----------------------------------------------------------------------------
// WHY THE API HAS TWO BASES
// -----------------------------------------------------------------------------
// On the HTTPS front (:8444) `/callapi` is same-origin. On QManager's own
// listener (:8080) that prefix does not exist — it belongs to the bridge — so the
// hook falls back to `https://<host>:8443/api`, which the bridge answers with
// permissive CORS. Dialling and listening therefore work from either origin;
// only the microphone needs the secure one.
//
// -----------------------------------------------------------------------------
// WHY THE CODE IS PCMU AND NOT OPUS
// -----------------------------------------------------------------------------
// The device's call audio is 8 kHz mono, and G.711 is mandatory in every WebRTC
// client, so the browser can be asked to speak it directly: no resampling, no
// transcoding. `setCodecPreferences` is belt and braces — the bridge registers
// only PCMU, so its answer already removes Opus.
// =============================================================================

const SAME_ORIGIN = "/callapi";
const FALLBACK_BASE = (host: string) => `https://${host}:8443/api`;

// One id for the incoming-call toast so a modem state change can dismiss it.
const INCOMING_TOAST_ID = "x16-incoming-call";
/** One id for the ordinary call-progress toasts, so they replace each other. */
const CALL_TOAST_ID = "x16-call";

export type LinkPhase = "idle" | "connecting" | "live" | "failed";
export type OutputRoute = "handset" | "speakerphone";

type AudioRouteMediaElement = HTMLAudioElement & {
  setSinkId?: (sinkId: string) => Promise<void>;
};
type AudioRouteMediaDevices = MediaDevices & {
  selectAudioOutput?: () => Promise<MediaDeviceInfo>;
};
type AudioSessionNavigator = Navigator & {
  audioSession?: { type: string };
};

export interface CallTerminal {
  state: CallTerminalState | null;
  /** True once the API has answered at least once. */
  available: boolean;
  /** True when this origin can capture audio (a secure context). */
  speak: boolean;
  /** Which API base answered, for the UI's own honesty. */
  apiBase: string;
  phase: LinkPhase;
  ice: string;
  error: string | null;
  micError: string | null;
  levels: { up: number; down: number };
  /** True when the live microphone is muted; silent, but the call continues. */
  muted: boolean;
  /** False when there is no microphone to mute (listen-only origin or no mic). */
  canMute: boolean;
  toggleMute: () => void;
  /** Client-side RNNoise on the microphone (hooks/use-noise-suppression). */
  noiseSuppression: {
    enabled: boolean;
    state: NsState;
    detail: string | null;
    setEnabled: (v: boolean) => void;
  };
  /** True while the speaker is gated because the far end is only hiss. */
  squelched: boolean;
  outputRoute: OutputRoute;
  outputRouteSupported: boolean;
  canRouteOutput: boolean;
  switchOutputRoute: () => Promise<boolean>;
  calls: CallRecord[];
  callsTotal: number;
  reloadCalls: () => Promise<void>;
  clearCalls: () => Promise<void>;
  connect: () => Promise<void>;
  disconnect: () => void;
  /** Answer an incoming call (ATA) / reject it. */
  answer: () => Promise<CallActionResponse>;
  reject: () => Promise<CallActionResponse>;
  recordings: RecordingInfo[];
  recordingsEnabled: boolean;
  deleteRecording: (name: string) => Promise<void>;
  setRecording: (on: boolean) => Promise<void>;
  contacts: Contact[];
  saveContact: (c: Omit<Contact, "id" | "source"> & { id?: number }) => Promise<void>;
  deleteContact: (id: number) => Promise<void>;
  importVcf: (text: string) => Promise<VcfImportResult | null>;
  dial: (number: string) => Promise<CallActionResponse>;
  hangup: () => Promise<CallActionResponse>;
  sendDtmf: (digit: string) => Promise<CallActionResponse>;
  setGain: (gain: { up?: number; down?: number }) => Promise<void>;
}

const IDLE_LEVELS = { up: 0, down: 0 };

export interface UseCallTerminalOptions {
  /** On the dedicated calls page, ask for mic access on entry and establish audio. */
  autoConnect?: boolean;
}

export function useCallTerminal({ autoConnect = false }: UseCallTerminalOptions = {}): CallTerminal {
  const { t } = useTranslation("common");
  const [state, setState] = useState<CallTerminalState | null>(null);
  const [available, setAvailable] = useState(false);
  const [speak, setSpeak] = useState(true);
  const [apiBase, setApiBase] = useState(SAME_ORIGIN);
  const [phase, setPhase] = useState<LinkPhase>("idle");
  const [ice, setIce] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [micError, setMicError] = useState<string | null>(null);
  const [levels, setLevels] = useState(IDLE_LEVELS);
  const [muted, setMuted] = useState(false);
  const [hasMic, setHasMic] = useState(false);
  const ns = useNoiseSuppression();
  const nsRef = useRef(ns);
  nsRef.current = ns;
  const outRef = useRef<MediaStream | null>(null);
  /** The suppressor's stream, i.e. the one the sender holds after replaceTrack. */
  const cookedRef = useRef<MediaStream | null>(null);
  const remoteRef = useRef<MediaStream | null>(null);
  const mutedRef = useRef(false);
  const [outputRoute, setOutputRoute] = useState<OutputRoute>("handset");
  const [outputRouteSupported, setOutputRouteSupported] = useState(false);
  const [outputReady, setOutputReady] = useState(false);
  const [calls, setCalls] = useState<CallRecord[]>([]);
  const [callsTotal, setCallsTotal] = useState(0);
  const [recordings, setRecordings] = useState<RecordingInfo[]>([]);
  const [recordingsEnabled, setRecordingsEnabled] = useState(false);
  const [contacts, setContacts] = useState<Contact[]>([]);

  const baseRef = useRef(SAME_ORIGIN);
  const callsTotalRef = useRef(0);
  const contactsTotalRef = useRef(-1);
  const recEnabledRef = useRef(false);
  const reloadCallsRef = useRef<() => Promise<void>>(async () => {});
  const pcRef = useRef<RTCPeerConnection | null>(null);
  const micRef = useRef<MediaStream | null>(null);
  const micTrackRef = useRef<MediaStreamTrack | null>(null);
  const sinkIdRef = useRef("");
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const acRef = useRef<AudioContext | null>(null);
  const upAnalyser = useRef<AnalyserNode | null>(null);
  const downAnalyser = useRef<AnalyserNode | null>(null);
  const meterTimer = useRef<number | null>(null);
  const autoAttempted = useRef(false);
  const previousLabel = useRef<string | null>(null);
  const ringRef = useRef<{ stop: () => void } | null>(null);
  const ringArmed = useRef(false);

  const postJson = useCallback(async <T,>(path: string, body?: unknown): Promise<T> => {
    const res = await fetch(`${baseRef.current}${path}`, {
      method: "POST",
      headers: body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!res.ok) {
      throw new Error(`${path}: HTTP ${res.status}`);
    }
    return (await res.json()) as T;
  }, []);

  // ----------------------------------------------------------------- polling --
  useEffect(() => {
    let cancelled = false;
    let timer: number | undefined;

    setSpeak(window.isSecureContext);
    const audio = document.createElement("audio") as AudioRouteMediaElement;
    const mediaDevices = navigator.mediaDevices as AudioRouteMediaDevices | undefined;
    // AudioSession can request the phone-call mode (play-and-record) but cannot
    // select receiver vs loudspeaker. The toggle is enabled only when the
    // browser exposes an actual output picker + sink assignment; otherwise it
    // stays visible but explains that the OS/browser owns the route. On insecure
    // LAN HTTP, navigator.mediaDevices itself may be undefined.
    setOutputRouteSupported(
      typeof audio.setSinkId === "function" &&
        typeof mediaDevices?.selectAudioOutput === "function"
    );

    const read = async () => {
      const candidates = [SAME_ORIGIN, FALLBACK_BASE(window.location.hostname)];
      let landed = false;
      for (const base of candidates) {
        try {
          const res = await fetch(`${base}/state`, { cache: "no-store" });
          if (!res.ok) {
            continue;
          }
          const next = (await res.json()) as CallTerminalState;
          if (cancelled) {
            return;
          }
          baseRef.current = base;
          setApiBase(base);
          setState(next);
          setAvailable(true);
          landed = true;
          // The bridge records a call when it ends, so a changed count is the
          // signal to pull the history again — no timer of its own.
          if (next.calls_total !== callsTotalRef.current) {
            callsTotalRef.current = next.calls_total;
            void reloadCallsRef.current();
            void reloadRecordings();
          }
          if (next.contacts_total !== contactsTotalRef.current) {
            contactsTotalRef.current = next.contacts_total;
            void reloadContacts();
          }
          recEnabledRef.current = next.record_enabled;
          if (next.record_enabled !== undefined) {
            setRecordingsEnabled(next.record_enabled);
          }
          break;
        } catch {
          // try the next base; the fallback is cross-origin and fails while the
          // certificate has not been trusted yet.
        }
      }
      if (!cancelled) {
        if (!landed) {
          setAvailable(false);
        }
        timer = window.setTimeout(read, 1000);
      }
    };

    void read();

    return () => {
      cancelled = true;
      if (timer !== undefined) {
        window.clearTimeout(timer);
      }
    };
  }, []);

  // ------------------------------------------------------------------ meters --
  const stopMeters = useCallback(() => {
    stopSquelch();
    if (meterTimer.current !== null) {
      window.clearInterval(meterTimer.current);
      meterTimer.current = null;
    }
    upAnalyser.current = null;
    downAnalyser.current = null;
    if (acRef.current) {
      void acRef.current.close();
      acRef.current = null;
    }
    setLevels(IDLE_LEVELS);
  }, []);

  // ---------------------------------------------------------------- squelch --
  // What the far end actually sends when nobody is talking is not digital silence:
  // the modem delivers a constant dither floor (measured -7x dBFS, 310 distinct
  // sample values, flat across 10 ms frames). On a phone speaker at volume that is
  // audible hiss on an empty call. A telephone gate — close slowly when the line is
  // only hiss, open instantly on speech — removes it without touching speech.
  const squelchRef = useRef<{ timer: number | null }>({ timer: null });
  const [squelched, setSquelched] = useState(false);

  const stopSquelch = useCallback(() => {
    if (squelchRef.current.timer !== null) {
      window.clearInterval(squelchRef.current.timer);
      squelchRef.current.timer = null;
    }
    setSquelched(false);
  }, []);

  const startSquelch = useCallback(() => {
    if (squelchRef.current.timer !== null) {
      return;
    }
    let quietFor = 0;
    squelchRef.current.timer = window.setInterval(() => {
      const analyser = downAnalyser.current;
      const audio = audioRef.current;
      if (!analyser || !audio) {
        return;
      }
      const buf = new Uint8Array(analyser.fftSize);
      analyser.getByteTimeDomainData(buf);
      let sum = 0;
      for (let i = 0; i < buf.length; i += 1) {
        const v = (buf[i] - 128) / 128;
        sum += v * v;
      }
      const rms = Math.sqrt(sum / buf.length);
      const dbfs = rms <= 0 ? -120 : 20 * Math.log10(rms);
      // Open instantly (a word must never be clipped), close only after a pause
      // longer than a breath and only while the line is down at its own floor.
      if (dbfs > -55) {
        quietFor = 0;
        if (audio.volume < 1) {
          audio.volume = Math.min(1, audio.volume + 0.34);
        }
        setSquelched(false);
      } else if (dbfs < -62) {
        quietFor += 100;
        if (quietFor >= 350) {
          if (audio.volume > 0.34) {
            audio.volume = Math.max(0, audio.volume - 0.34);
          } else {
            audio.volume = 0;
            setSquelched(true);
          }
        }
      }
    }, 100);
  }, []);

  const startMeters = useCallback((remote: MediaStream | null) => {
    const mic = micRef.current;
    const ac = new AudioContext();
    acRef.current = ac;
    if (ac.state === "suspended") {
      void ac.resume();
    }
    if (mic) {
      upAnalyser.current = ac.createAnalyser();
      upAnalyser.current.fftSize = 512;
      ac.createMediaStreamSource(mic).connect(upAnalyser.current);
    }
    if (remote) {
      downAnalyser.current = ac.createAnalyser();
      downAnalyser.current.fftSize = 512;
      ac.createMediaStreamSource(remote).connect(downAnalyser.current);
    }

    startSquelch();

    const peak = (analyser: AnalyserNode | null): number => {
      if (!analyser) {
        return 0;
      }
      const buf = new Uint8Array(analyser.fftSize);
      analyser.getByteTimeDomainData(buf);
      let max = 0;
      for (let i = 0; i < buf.length; i += 1) {
        const v = Math.abs(buf[i] - 128) / 128;
        if (v > max) {
          max = v;
        }
      }
      return max;
    };

    meterTimer.current = window.setInterval(() => {
      setLevels({ up: peak(upAnalyser.current), down: peak(downAnalyser.current) });
    }, 120);
  }, []);

  // ------------------------------------------------------------------ mute --
  // Muting is the TRACK, not the connection: `enabled = false` turns the outgoing
  // audio into silence while the peer, the call and the downlink all continue.
  // Anything else (closing the peer, stopping the track) would drop the call back
  // to one-way or drop it entirely, which is not what a mute button means.
  useEffect(() => {
    mutedRef.current = muted;
  }, [muted]);

  // The speaker element follows the call, not the peer connection. A peer stays
  // connected between calls, and the modem's downlink is not digital silence, so
  // leaving the element playing makes the far end's line hiss audible in an empty
  // room with nobody on the call.
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) {
      return;
    }
    const inCall = (state?.call ?? "") !== "";
    if (inCall && audio.paused) {
      void audio.play().catch(() => undefined);
    } else if (!inCall && !audio.paused) {
      audio.pause();
    }
  }, [state?.call]);

  const toggleMute = useCallback(() => {
    const next = !mutedRef.current;
    // Mute is applied to every track we might be sending: the processed one (what
    // the sender holds after the suppressor swaps in), the raw microphone (which is
    // still live behind the worklet), and the graph itself. One of them being
    // missed is exactly how "muted" ends up audible — or how unmuting stays silent
    // because the track that was disabled is not the track on the wire.
    micTrackRef.current && (micTrackRef.current.enabled = !next);
    const raw = micRef.current?.getAudioTracks()[0];
    if (raw) {
      raw.enabled = !next;
    }
    cookedRef.current?.getAudioTracks().forEach((t) => {
      t.enabled = !next;
    });
    nsRef.current.setMuted(next);
    mutedRef.current = next;
    setMuted(next);
  }, []);

  // `play-and-record` is the standardized web AudioSession mode for a voice call
  // and lets the platform choose its call route (often the handset receiver on a
  // phone). It is NOT a speakerphone switch. Only setSinkId + selectAudioOutput
  // can select a distinct, permitted sink; where those are absent, the button is
  // disabled with an explanation rather than pretending AudioSession.type can
  // force a speaker route.
  /**
   * Put a working microphone back on the wire when the suppressor cannot deliver.
   *
   * This exists because suppression is ON by default: the microphone is captured
   * with the browser's own suppressor OFF, so if ours fails the far end would hear
   * the rawest microphone this device can produce — worse than before the feature.
   * Preference order is the browser's suppressor, then the raw track.
   */
  const rescueMic = useCallback(
    async (reason: string) => {
      const pc = pcRef.current;
      const sender = pc?.getSenders().find((s2) => s2.track?.kind === "audio");
      if (!pc || !sender || pc.connectionState === "closed") {
        return;
      }
      if (window.isSecureContext) {
        try {
          const rescued = await navigator.mediaDevices.getUserMedia({
            audio: {
              channelCount: 1,
              echoCancellation: true,
              noiseSuppression: true,
              autoGainControl: true,
            },
          });
          const track = rescued.getAudioTracks()[0];
          if (track) {
            await sender.replaceTrack(track);
            track.enabled = !mutedRef.current;
            outRef.current = rescued;
            micTrackRef.current = track;
            startMeters(remoteRef.current);
            setError(`noise suppression off (${reason}); the browser's own suppressor is in use`);
            return;
          }
        } catch {
          // Fall through to the raw track below.
        }
      }
      const raw = micRef.current?.getAudioTracks()[0];
      if (raw) {
        try {
          await sender.replaceTrack(raw);
          raw.enabled = !mutedRef.current;
          micTrackRef.current = raw;
          startMeters(remoteRef.current);
          setError(`noise suppression off (${reason}); the raw microphone is in use`);
        } catch {
          setError(`noise suppression failed (${reason}) and the microphone could not be restored`);
        }
      }
    },
    [startMeters]
  );

  const switchOutputRoute = useCallback(async () => {
    const nav = navigator as AudioSessionNavigator;
    const audio = audioRef.current as AudioRouteMediaElement | null;
    const mediaDevices = navigator.mediaDevices as AudioRouteMediaDevices | undefined;
    if (!mediaDevices) {
      return false;
    }
    const devices = mediaDevices;
    const hasSinkPicker = Boolean(audio?.setSinkId && devices.selectAudioOutput);
    if (!hasSinkPicker || !audio?.setSinkId || !devices.selectAudioOutput) {
      return false;
    }

    try {
      if (outputRoute === "speakerphone") {
        await audio.setSinkId("");
        sinkIdRef.current = "";
        if (nav.audioSession) {
          nav.audioSession.type = "play-and-record";
        }
        setOutputRoute("handset");
        return true;
      }

      if (hasSinkPicker) {
        // Must be called from the route button's user gesture. Browser/OS shows
        // only output devices it actually exposes (the handset may not appear).
        const output = await devices.selectAudioOutput();
        await audio.setSinkId(output.deviceId);
        sinkIdRef.current = output.deviceId;
        if (nav.audioSession) {
          nav.audioSession.type = "play-and-record";
        }
      }
      setOutputRoute("speakerphone");
      return true;
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      return false;
    }
  }, [outputRoute]);

  // -------------------------------------------------------------- shortcut --
  // "M" mutes. It is ignored while a text field has focus (the dialler's number
  // input is the obvious case — typing a name or number must never silence the
  // microphone) and while a modifier is held, so ⌘M/ctrl-M keep their browser
  // meaning. The handler lives here so both surfaces get it from one place.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey) {
        return;
      }
      if (event.key !== "m" && event.key !== "M") {
        return;
      }
      const el = event.target as HTMLElement | null;
      const tag = el?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el?.isContentEditable) {
        return;
      }
      event.preventDefault();
      toggleMute();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [toggleMute]);

  // --------------------------------------------------------------- history --
  const reloadCalls = useCallback(async () => {
    try {
      const res = await fetch(`${baseRef.current}/calls?limit=50`, { cache: "no-store" });
      if (!res.ok) {
        return;
      }
      const data = (await res.json()) as CallLogResponse;
      setCalls(data.calls ?? []);
      setCallsTotal(data.total ?? 0);
      callsTotalRef.current = data.total ?? 0;
    } catch {
      // A failed read keeps the rows already on screen.
    }
  }, []);
  reloadCallsRef.current = reloadCalls;

  const reloadRecordings = useCallback(async () => {
    try {
      const res = await fetch(`${baseRef.current}/recordings`, { cache: "no-store" });
      if (!res.ok) {
        return;
      }
      const data = (await res.json()) as { recordings: RecordingInfo[]; enabled: boolean };
      setRecordings(data.recordings ?? []);
      setRecordingsEnabled(Boolean(data.enabled));
    } catch {
      // keep what is on screen
    }
  }, []);

  const reloadContacts = useCallback(async () => {
    try {
      const res = await fetch(`${baseRef.current}/contacts`, { cache: "no-store" });
      if (!res.ok) {
        return;
      }
      const data = (await res.json()) as { contacts: Contact[] };
      setContacts(data.contacts ?? []);
    } catch {
      // keep what is on screen
    }
  }, []);

  const deleteRecording = useCallback(
    async (name: string) => {
      try {
        await fetch(`${baseRef.current}/recordings/${encodeURIComponent(name)}`, {
          method: "DELETE",
        });
        await reloadRecordings();
      } catch {
        // ignore
      }
    },
    [reloadRecordings]
  );

  const setRecording = useCallback(async (on: boolean) => {
    try {
      const res = await fetch(`${baseRef.current}/record`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ on }),
      });
      if (res.ok) {
        const data = (await res.json()) as { on?: boolean };
        setRecordingsEnabled(Boolean(data.on));
      }
    } catch {
      // ignore
    }
  }, []);

  const saveContact = useCallback(
    async (c: Omit<Contact, "id" | "source"> & { id?: number }) => {
      try {
        await fetch(`${baseRef.current}/contacts`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(c),
        });
        await reloadContacts();
      } catch {
        // ignore
      }
    },
    [reloadContacts]
  );

  const deleteContact = useCallback(
    async (id: number) => {
      try {
        await fetch(`${baseRef.current}/contacts?id=${id}`, { method: "DELETE" });
        await reloadContacts();
      } catch {
        // ignore
      }
    },
    [reloadContacts]
  );

  const importVcf = useCallback(
    async (text: string) => {
      try {
        const res = await fetch(`${baseRef.current}/contacts/import`, {
          method: "POST",
          headers: { "Content-Type": "text/vcard" },
          body: text,
        });
        if (!res.ok) {
          return null;
        }
        const data = (await res.json()) as VcfImportResult;
        await reloadContacts();
        return data;
      } catch {
        return null;
      }
    },
    [reloadContacts]
  );

  const clearCalls = useCallback(async () => {
    try {
      const res = await fetch(`${baseRef.current}/calls`, { method: "DELETE" });
      if (res.ok) {
        setCalls([]);
        setCallsTotal(0);
        callsTotalRef.current = 0;
      }
    } catch {
      // ignore: the list simply stays
    }
  }, []);

  // -------------------------------------------------------------------- link --
  const disconnect = useCallback(() => {
    stopMeters();
    if (pcRef.current) {
      pcRef.current.close();
      pcRef.current = null;
    }
    if (micRef.current) {
      micRef.current.getTracks().forEach((t) => t.stop());
      micRef.current = null;
    }
    micTrackRef.current = null;
    setMuted(false);
    setHasMic(false);
    if (audioRef.current) {
      audioRef.current.pause();
      audioRef.current.srcObject = null;
      audioRef.current = null;
    }
    sinkIdRef.current = "";
    outRef.current = null;
    remoteRef.current = null;
    setOutputReady(false);
    const audioNav = navigator as AudioSessionNavigator;
    if (audioNav.audioSession) {
      audioNav.audioSession.type = "auto";
    }
    setOutputRoute("handset");
    setPhase("idle");
    setIce("");
  }, [stopMeters]);

  const connect = useCallback(async () => {
    setError(null);
    setMicError(null);
    setPhase("connecting");

    const audioNav = navigator as AudioSessionNavigator;
    if (audioNav.audioSession) {
      audioNav.audioSession.type = "play-and-record";
    }

    // Microphone only where the browser will give one; otherwise the peer is
    // still opened, receive-only, so the call can be listened to.
    if (window.isSecureContext) {
      try {
        micRef.current = await navigator.mediaDevices.getUserMedia({
          audio: {
            channelCount: 1,
            echoCancellation: true,
            // Never stack two suppressors: ours is a DNN and the browser's own NS
            // is a spectral gate, and in series they produce musical noise and
            // clipped consonants. Whichever one the operator asked for, only one
            // is active.
            noiseSuppression: !nsRef.current.enabled,
            // AGC is OFF with our suppressor on, and this was measured, not
            // guessed: the recording of 20261028-192436 shows the uplink noise
            // floor climbing -59 -> -53 -> -21 dBFS in three seconds while nobody
            // was speaking, then sagging back. That is a slow AGC winding up on a
            // quiet microphone — and suppression makes it worse, because gating the
            // pauses to digital silence tells the AGC the input is even quieter.
            // RNNoise keeps speech level stable on its own (measured -0.3..-2 dB),
            // so the gain control it would fight is the one we must not have.
            autoGainControl: !nsRef.current.enabled,
          },
        });
        micTrackRef.current = micRef.current.getAudioTracks()[0] ?? null;
        setHasMic(micTrackRef.current !== null);
      } catch (err) {
        setMicError(err instanceof Error ? err.message : String(err));
        setHasMic(false);
      }
    }

    try {
      const pc = new RTCPeerConnection({ iceServers: [], bundlePolicy: "max-bundle" });
      pcRef.current = pc;

      const mic = micRef.current;
      const transceiver = mic
        ? pc.addTransceiver(mic.getAudioTracks()[0], { direction: "sendrecv" })
        : pc.addTransceiver("audio", { direction: "recvonly" });

      // Suppression is swapped in AFTER the peer is up, never before: the raw
      // microphone is already on the transceiver, so a worklet that is slow to
      // instantiate costs a few hundred ms of unprocessed audio instead of a few
      // hundred ms of silence.
      if (mic && nsRef.current.enabled) {
        void nsRef.current.process(mic).then(async (outgoing) => {
          outRef.current = outgoing;
          const track = outgoing.getAudioTracks()[0];
          const sender = pc.getSenders().find((s2) => s2.track?.kind === "audio");
          if (!track || !sender || pc.connectionState === "closed") {
            return;
          }
          if (track === mic.getAudioTracks()[0] && nsRef.current.state === "failed") {
            // Suppression is on by default, and the microphone was captured with
            // the browser's own suppressor OFF so the two could not stack. If our
            // worklet did not start, that leaves the far end with the rawest mic
            // this device can produce — worse than the default we shipped before.
            // Re-capture with the browser's suppressor and put THAT on the wire.
            try {
              const rescued = await navigator.mediaDevices.getUserMedia({
                audio: {
                  channelCount: 1,
                  echoCancellation: true,
                  noiseSuppression: true,
                  autoGainControl: true,
                },
              });
              const rescuedTrack = rescued.getAudioTracks()[0];
              // Already past the "closed" guard above, so the peer is still live.
              if (rescuedTrack) {
                await sender.replaceTrack(rescuedTrack);
                rescuedTrack.enabled = !mutedRef.current;
                outRef.current = rescued;
                micTrackRef.current = rescuedTrack;
                startMeters(remoteRef.current);
              }
            } catch {
              // No rescue available: the raw track stays, and the card already
              // says suppression is unavailable.
            }
            return;
          }
          if (track !== mic.getAudioTracks()[0]) {
            const swap = await sender
              .replaceTrack(track)
              .then(() => true)
              .catch(() => false);
            if (!swap) {
              // replaceTrack rejected: the sender still holds the raw microphone,
              // so the call keeps audio — say why the suppressor is not in use.
              setError("noise suppression off (the browser refused the processed microphone)");
              return;
            }
            cookedRef.current = outgoing;
            // Mute follows the track that is actually on the wire.
            track.enabled = !mutedRef.current;
            micTrackRef.current = track;
            // Meters must read what the far end hears, not the raw microphone.
            startMeters(remoteRef.current);
          }
        });
      }

      try {
        const caps = RTCRtpReceiver.getCapabilities("audio");
        const pcmu = (caps?.codecs ?? []).filter((c) => c.mimeType === "audio/PCMU");
        if (pcmu.length > 0) {
          transceiver.setCodecPreferences(pcmu);
        }
      } catch {
        // Older Safari: the bridge's answer is PCMU-only anyway.
      }

      pc.ontrack = (event) => {
        const stream = event.streams[0] ?? new MediaStream([event.track]);
        remoteRef.current = stream;
        const audio = new Audio() as AudioRouteMediaElement;
        audio.autoplay = true;
        audio.srcObject = stream;
        audioRef.current = audio;
        setOutputReady(true);
        if (sinkIdRef.current && audio.setSinkId) {
          void audio.setSinkId(sinkIdRef.current).catch(() => {
            sinkIdRef.current = "";
            setOutputRoute("handset");
          });
        }
        void audio.play().catch(() => {
          // Autoplay refusal shows up as a silent downlink meter.
        });
        startMeters(stream);
      };

      pc.oniceconnectionstatechange = () => {
        setIce(pc.iceConnectionState);
        if (pc.iceConnectionState === "failed") {
          setPhase("failed");
          setError("ICE could not find a path — check UDP 50000-50100 and the certificate");
        }
      };

      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      const answer = await postJson<RTCSessionDescriptionInit>("/offer", pc.localDescription);
      await pc.setRemoteDescription(answer);
      setPhase("live");
      if (!downAnalyser.current) {
        startMeters(null);
      }
    } catch (err) {
      setPhase("failed");
      setError(err instanceof Error ? err.message : String(err));
      disconnect();
    }
  }, [disconnect, postJson, startMeters]);

  // The standalone calls page opens the mic prompt on entry when this is a
  // secure origin. The browser remembers an accepted/rejected permission per
  // origin; we do not persist a second, misleading copy in localStorage. On the
  // plain-HTTP QManager port the same auto-open creates a receive-only peer.
  useEffect(() => {
    if (!autoConnect || !available || autoAttempted.current || phase !== "idle") {
      return;
    }
    autoAttempted.current = true;
    void connect();
  }, [autoConnect, available, connect, phase]);

  // A suppressor that runs and then dies (context suspended, worklet silent) is
  // worse than one that never started: the sender is already pointing at its
  // track. Hand the microphone back the moment the hook says so.
  useEffect(() => {
    if (ns.state === "failed" && ns.detail && phase === "live") {
      void rescueMic(ns.detail);
    }
  }, [ns.state, ns.detail, phase, rescueMic]);

  // -------------------------------------------------------------- progress --
  // Phone behaviour, twice: a tone when the call connects, a lower one when it
  // ends. Generated, not sampled — no asset to ship or fail to load.
  const beep = useCallback((tone: typeof ANSWER_BEEP | typeof END_BEEP) => {
    try {
      const ctx = new AudioContext();
      const now = ctx.currentTime + 0.02;
      for (let p = 0; p < tone.pulses; p += 1) {
        const at = now + (p * (tone.ms + tone.gapMs)) / 1000;
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        const len = tone.ms / 1000;
        osc.type = "sine";
        osc.frequency.value = tone.hz;
        gain.gain.setValueAtTime(0, at);
        gain.gain.linearRampToValueAtTime(tone.gain, at + 0.008);
        gain.gain.setValueAtTime(tone.gain, at + len - 0.008);
        gain.gain.linearRampToValueAtTime(0, at + len);
        osc.connect(gain).connect(ctx.destination);
        osc.start(at);
        osc.stop(at + len + 0.01);
      }
      const total = ((tone.pulses * (tone.ms + tone.gapMs)) / 1000 + 0.2) * 1000;
      window.setTimeout(() => void ctx.close().catch(() => undefined), total);
    } catch {
      // No audio context (backgrounded page, autoplay policy): the toast still says
      // what happened. Never let a courtesy tone break a call.
    }
  }, []);

  const lastTone = useRef<string>("");
  useEffect(() => {
    const label = state?.call_label;
    if (!label) {
      return;
    }
    if (label === "active" && lastTone.current !== "active") {
      lastTone.current = "active";
      beep(ANSWER_BEEP);
    } else if ((label === "ended" || label === "idle") && lastTone.current === "active") {
      lastTone.current = label === "idle" ? "idle" : "ended";
      beep(END_BEEP);
    } else if (label === "incoming" || label === "ringing") {
      lastTone.current = "ringing";
    }
  }, [state?.call_label, beep]);

  // ------------------------------------------------------------------- ring --
  // An incoming call has to be audible before it is readable. The cadence is
  // generated, not a bundled mp3: one oscillator through a gain envelope costs
  // nothing on a phone and cannot 404. Browsers block audio until a gesture, so
  // a page opened but never touched stays silent — `ringArmed` retries on the
  // first pointer/key event instead of pretending it rang.
  const stopRing = useCallback(() => {
    ringRef.current?.stop();
    ringRef.current = null;
    navigator.vibrate?.(0);
  }, []);

  const startRing = useCallback(() => {
    if (ringRef.current) {
      return;
    }
    let ctx: AudioContext | null = null;
    let timer: number | undefined;
    let closed = false;
    const beep = (at: number) => {
      if (!ctx) {
        return;
      }
      const hold = RING_BEEP_MS / 1000 - RING_RAMP_S;
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = "sine";
      osc.frequency.value = 440;
      gain.gain.setValueAtTime(0, at);
      gain.gain.linearRampToValueAtTime(RING_GAIN, at + RING_RAMP_S);
      gain.gain.setValueAtTime(RING_GAIN, at + hold);
      gain.gain.linearRampToValueAtTime(0, at + hold + RING_RAMP_S);
      osc.connect(gain).connect(ctx.destination);
      osc.start(at);
      osc.stop(at + RING_BEEP_MS / 1000 + RING_RAMP_S);
    };
    const cycle = () => {
      if (closed || !ctx) {
        return;
      }
      const now = ctx.currentTime + 0.02;
      for (const offset of RING_BEEPS_MS) {
        beep(now + offset / 1000);
      }
      navigator.vibrate?.(RING_VIBRATE_MS as number[]);
    };
    const begin = () => {
      if (closed) {
        return;
      }
      // Reuse the meters' context when the link is already live: that one was
      // created after a user gesture and is therefore allowed to make sound. A
      // fresh context on a page nobody has touched is suspended by autoplay
      // policy, so it is armed and retried on the first interaction rather than
      // assumed audible.
      if (!ctx) {
        const shared = acRef.current;
        ctx = shared && shared.state === "running" ? shared : new AudioContext();
      }
      if (ctx.state === "suspended") {
        // Autoplay policy: no gesture has happened yet. Ask, and try again on
        // the first interaction rather than ringing silently forever.
        void ctx.resume();
        ringArmed.current = true;
        return;
      }
      ringArmed.current = false;
      cycle();
      timer = window.setInterval(cycle, RING_CYCLE_MS);
    };
    ringRef.current = {
      stop: () => {
        closed = true;
        if (timer !== undefined) {
          window.clearInterval(timer);
        }
        if (ctx && ctx !== acRef.current) {
          void ctx.close();
        }
        ctx = null;
      },
    };
    begin();
  }, []);

  useEffect(() => {
    if (state?.call_label === "incoming") {
      startRing();
    } else {
      stopRing();
    }
    return stopRing;
  }, [state?.call_label, startRing, stopRing]);

  useEffect(() => {
    if (!ringArmed.current) {
      return;
    }
    const arm = () => {
      if (state?.call_label === "incoming" && !ringRef.current) {
        startRing();
      }
    };
    window.addEventListener("pointerdown", arm, { once: true });
    window.addEventListener("keydown", arm, { once: true });
    return () => {
      window.removeEventListener("pointerdown", arm);
      window.removeEventListener("keydown", arm);
    };
  }, [state?.call_label, startRing]);

  // -------------------------------------------------------------------- call --
  const dial = useCallback(
    async (number: string) => {
      try {
        return await postJson<CallActionResponse>("/call", { number });
      } catch (err) {
        return { ok: false, error: err instanceof Error ? err.message : String(err) };
      }
    },
    [postJson]
  );

  const answer = useCallback(async () => {
    try {
      return await postJson<CallActionResponse>("/answer");
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) };
    }
  }, [postJson]);

  const reject = useCallback(async () => {
    try {
      return await postJson<CallActionResponse>("/reject");
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) };
    }
  }, [postJson]);

  const hangup = useCallback(async () => {
    try {
      return await postJson<CallActionResponse>("/hangup");
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) };
    }
  }, [postJson]);

  // Animated Sonner toasts announce only actual modem state transitions. Initial
  // page load is quiet; repeated 1s polls of the same state do not duplicate them.
  useEffect(() => {
    const next = state?.call_label;
    if (next === undefined) {
      return;
    }
    const prev = previousLabel.current;
    previousLabel.current = next;
    if (prev === null || prev === next) {
      return;
    }
    const who = displayName(contacts, state?.call_number ?? state?.number ?? "");
    switch (next) {
      case "dialing":
        // Placing a call used to be the one state with no announcement at all, so
        // pressing Dial looked like nothing happened until the far end picked up.
        toast.loading(t("calls.toast.dialing_title"), {
          id: CALL_TOAST_ID,
          description: t("calls.toast.dialing_body", { who }),
        });
        break;
      case "ringing":
        toast.info(t("calls.toast.ringing_title"), {
          id: CALL_TOAST_ID,
          description: t("calls.toast.ringing_body", { who }),
        });
        break;
      case "held":
        toast.info(t("calls.toast.held_title"), { id: CALL_TOAST_ID, description: who });
        break;
      case "waiting":
        toast.info(t("calls.toast.waiting_title"), { id: CALL_TOAST_ID, description: who });
        break;
      case "incoming":
        // The toast IS the answer screen for a call nobody is looking at. It
        // persists while the modem rings (`duration: Infinity`) and carries the
        // two decisions, so answering never requires finding the Calls card
        // first. A fixed id lets the state change dismiss it below.
        toast.info(t("calls.toast.incoming_title"), {
          id: INCOMING_TOAST_ID,
          description: t("calls.toast.incoming_body", { who }),
          duration: Infinity,
          action: {
            label: t("calls.toast.answer"),
            onClick: () => void answer(),
          },
          cancel: {
            label: t("calls.toast.reject"),
            onClick: () => void reject(),
          },
        });
        break;
      case "active":
        toast.dismiss(INCOMING_TOAST_ID);
        toast.success(t("calls.toast.active_title"), {
          id: CALL_TOAST_ID,
          description: t("calls.toast.active_body", { who }),
        });
        break;
      case "ended":
        toast.dismiss(INCOMING_TOAST_ID);
        toast.info(t("calls.toast.ended_title"), {
          id: CALL_TOAST_ID,
          description: t("calls.toast.ended_body", {
            who,
            outcome: t(`calls.history.outcome.${state?.last_outcome ?? "failed"}`),
          }),
        });
        break;
      case "idle":
        toast.dismiss(INCOMING_TOAST_ID);
        if (prev === "ended") {
          toast.info(t("calls.toast.idle_title"), {
            description: t("calls.toast.idle_body"),
          });
        }
        break;
    }
  }, [contacts, state, t, answer, reject]);

  const sendDtmf = useCallback(
    async (digit: string) => {
      try {
        return await postJson<CallActionResponse>(
          `/dtmf?digit=${encodeURIComponent(digit)}`
        );
      } catch (err) {
        return { ok: false, error: err instanceof Error ? err.message : String(err) };
      }
    },
    [postJson]
  );

  const setGain = useCallback(
    async (gain: { up?: number; down?: number }) => {
      try {
        await postJson<GainResponse>("/gain", gain);
      } catch {
        // A failed gain write is not worth a toast: the next poll reports what
        // the bridge actually holds.
      }
    },
    [postJson]
  );

  // First load: the book and the recordings are page furniture, not per-call.
  useEffect(() => {
    void reloadContacts();
    void reloadRecordings();
  }, [reloadContacts, reloadRecordings]);

  useEffect(() => disconnect, [disconnect]);

  return {
    state,
    available,
    speak,
    apiBase,
    phase,
    ice,
    error,
    micError,
    levels,
    muted,
    canMute: phase === "live" && hasMic,
    toggleMute,
    noiseSuppression: {
      enabled: ns.enabled,
      state: ns.state,
      detail: ns.detail,
      setEnabled: ns.setEnabled,
    },
    squelched,
    outputRoute,
    outputRouteSupported,
    canRouteOutput: outputRouteSupported && outputReady && phase === "live",
    switchOutputRoute,
    calls,
    callsTotal,
    reloadCalls,
    clearCalls,
    connect,
    disconnect,
    answer,
    reject,
    recordings,
    recordingsEnabled,
    deleteRecording,
    setRecording,
    contacts,
    saveContact,
    deleteContact,
    importVcf,
    dial,
    hangup,
    sendDtmf,
    setGain,
  };
}
