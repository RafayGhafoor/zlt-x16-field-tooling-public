// =============================================================================
// Call terminal (X16) — wire types
// =============================================================================
// These mirror the JSON served by the on-device call bridge
// (/data/webrtc/bin/x16-webrtc, see router-fix/voip-bridge/). The bridge is the
// only implementation of this API; nothing here is derived from a CGI.
//
// The bridge is reached at `/callapi/*` on the SAME origin. That is deliberate:
// QManager itself is served by busybox httpd on :8080 with no TLS, and
// getUserMedia() is refused outside a secure context. The bridge's HTTPS
// listener (:8444) reverse-proxies QManager, so the page at
// https://192.168.3.1:8444/cellular/calls is the same export, same origin, and
// the microphone is allowed. On http://192.168.3.1:8080 the same page renders
// listen-only and says why — see `useSecureContext`.
// =============================================================================

/** Modem call state from AT+CLCC, `""` when there is no call. */
// "unknown" is the bridge's own answer when the AT broker stops replying: the
// modem's state is not idle, and pretending it is "active" is what left a
// finished call on screen with a hang-up button that could not work.
export type CallStateCode = "" | "0" | "1" | "2" | "3" | "4" | "5" | "unknown";

export interface CallTerminalState {
  call: CallStateCode;
  call_label: string;
  number: string;
  ice: string;
  tap: boolean;
  tap_note: string;
  tap_age_s: number;
  tap_restarts: number;
  tap_last_exit: string;
  dl_frames: number;
  dl_bytes: number;
  ul_frames: number;
  ul_bytes: number;
  /** Milliseconds since the last downlink packet, or -1 if none ever arrived. */
  dl_age_ms: number;
  ul_gain: number;
  dl_gain: number;
  /** The number and direction the MODEM reports (covers incoming calls). */
  call_number: string;
  call_dir: string;
  /** Unix seconds of the last call end, for the "ended" state. */
  call_ended_at: number;
  last_outcome: string;
  /** Number of browser devices joined to the current media bridge (max four). */
  peers: number;
  /** The bridge stopped issuing AT after a modem request timed out. */
  at_quarantined: boolean;
  at_note: string;
  /** True while a recording is being written. */
  recording: boolean;
  /** Whether recording is enabled at all. */
  record_enabled: boolean;
  recordings_total: number;
  contacts_total: number;
  /** Recorded calls the device is holding (the log's own count). */
  calls_total: number;
  /** SHA-256 of the local CA, for the trust instructions. */
  ca_fingerprint: string;
  last_at: string;
}

export interface CallActionResponse {
  ok: boolean;
  at?: string;
  error?: string;
}

export interface GainResponse {
  ok: boolean;
  up: number;
  down: number;
}

/** One finished call, as recorded by the device (JSON lines in its log). */
export interface CallRecord {
  id: number;
  number: string;
  direction: "outgoing" | "incoming";
  /** Unix seconds. */
  started_at: number;
  /** 0 when the call was never answered. */
  answered_at: number;
  ended_at: number;
  /** Talk time — 0 for a call that was never answered. */
  seconds: number;
  outcome: "answered" | "no_answer" | "missed" | "failed";
}

export interface CallLogResponse {
  calls: CallRecord[];
  total: number;
}

export interface RecordingInfo {
  name: string;
  number: string;
  /** "outgoing" | "incoming" | "call" */
  direction: string;
  started_at: number;
  seconds: number;
  bytes: number;
}

export interface Contact {
  id: number;
  name: string;
  company: string;
  phone: string;
  email: string;
  source: string;
}

export interface VcfImportResult {
  ok: boolean;
  imported: number;
  updated: number;
  skipped: number;
  seen: number;
  total: number;
}
