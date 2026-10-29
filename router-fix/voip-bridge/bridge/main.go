// x16-webrtc — a browser audio terminal for the ZLT X16's cellular calls.
//
//	Browser mic  --WebRTC/PCMU 8 kHz-->  this process  --UDP PCM-->  x16-audio --PCMIO--> VoLTE uplink
//	Browser spk  <--WebRTC/PCMU 8 kHz--  this process  <--UDP PCM--  x16-audio <--PCMIO-- VoLTE downlink
//
// Why PCMU and not Opus: the X16's call audio is 8 kHz mono S16_LE and G.711 is
// the one codec every WebRTC browser must implement, so the bridge needs no
// resampling and no cgo/libopus — it cross-compiles as a pure Go static binary
// and costs a fraction of one ARMv7 core.
//
// The process owns three things:
//   - the WebRTC peer (signalling over HTTPS, one peer at a time)
//   - the two loopback PCM streams to `x16-audio` (the PCMIO tap pump)
//   - call control through /bin/atcmd (ATD / ATH / AT+CLCC)
//
// The tap is opened only while a call is answered and is restarted if it dies,
// because the vendor PCMIO stream stops on its own when the voice usecase ends.

package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"

	"x16webrtc/g711"
)

//go:embed index.html
var indexHTML []byte

const (
	sampleRate   = 8000
	frameSamples = 160              // 20 ms
	frameBytes   = frameSamples * 2 // S16 mono
	ulawPerFrame = frameSamples
)

type bridge struct {
	api   *webrtc.API
	track *webrtc.TrackLocalStaticRTP

	certPath string
	caPath   string
	caPrint  string
	calls    *callLog
	rec      *Recorder
	book     *contactStore

	tapBin     string
	dlPort     int
	ulPort     int
	ulAddr     *net.UDPAddr
	ulConn     *net.UDPConn
	dlConn     *net.UDPConn
	atBin      string
	stopPoller bool

	seq  uint16
	ts   uint32
	ssrc uint32
	txMu sync.Mutex

	gainMu sync.RWMutex
	ulGain float64
	dlGain float64

	dlFrames, dlBytes, dlErr atomic.Uint64
	ulFrames, ulBytes, ulErr atomic.Uint64
	lastDL                   atomic.Int64 // unix nanos

	peerMu        sync.Mutex
	peers         map[uint64]*webrtc.PeerConnection
	peerICE       map[uint64]string
	peerDropTimer map[uint64]*time.Timer
	pendingPeer   int
	nextPeerID    uint64
	mixer         *uplinkMixer

	callMu      sync.Mutex
	callState   string // "", "2", "3", "0", …
	callNum     string // the number we dialled
	callNumber  string // the number the MODEM reports (also covers incoming)
	callDir     string // "0" outgoing, "1" incoming
	callEndedAt int64  // unix seconds of the last call end, for the "ended" chip
	lastOutcome string
	callAt      time.Time
	lastAT      string
	atMu        sync.Mutex
	atPoisoned  atomic.Value // string: last AT request that timed out after acquiring the shared lock

	tapMu       sync.Mutex
	tapCmd      *exec.Cmd
	tapDone     chan struct{}
	tapSince    time.Time
	tapRestarts int
	tapLastExit string
	tapWedgeRun int    // consecutive opens that the vendor tap never answered
	tapNote     string // operator-facing explanation when the tap is blocked
}

func newBridge(tapBin, atBin string, dlPort, ulPort int) (*bridge, error) {
	media := &webrtc.MediaEngine{}
	if err := media.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:  webrtc.MimeTypePCMU,
			ClockRate: sampleRate,
			Channels:  1,
		},
		PayloadType: 0,
	}, webrtc.RTPCodecTypeAudio); err != nil {
		return nil, fmt.Errorf("register PCMU: %w", err)
	}

	se := webrtc.SettingEngine{}
	// Pin media to a small, fixed UDP range so the deployment can open exactly
	// those ports on the LAN side instead of "whatever the kernel hands out".
	if err := se.SetEphemeralUDPPortRange(50000, 50100); err != nil {
		return nil, fmt.Errorf("udp port range: %w", err)
	}
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})

	api := webrtc.NewAPI(webrtc.WithMediaEngine(media), webrtc.WithSettingEngine(se))

	track, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{
		MimeType:  webrtc.MimeTypePCMU,
		ClockRate: sampleRate,
		Channels:  1,
	}, "x16-call-audio", "x16")
	if err != nil {
		return nil, err
	}

	ulAddr, err := net.ResolveUDPAddr("udp", fmt.Sprintf("127.0.0.1:%d", ulPort))
	if err != nil {
		return nil, err
	}
	ulConn, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, err
	}
	dlConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: dlPort})
	if err != nil {
		return nil, fmt.Errorf("bind downlink udp %d: %w", dlPort, err)
	}

	return &bridge{
		api: api, track: track,
		peers:         make(map[uint64]*webrtc.PeerConnection),
		peerICE:       make(map[uint64]string),
		peerDropTimer: make(map[uint64]*time.Timer),
		mixer:         newUplinkMixer(),
		tapBin:        tapBin, atBin: atBin,
		dlPort: dlPort, ulPort: ulPort,
		ulAddr: ulAddr, ulConn: ulConn, dlConn: dlConn,
		ssrc:   0x58313643, // "X16C"
		ulGain: 1.0, dlGain: 1.0,
	}, nil
}

// ---------------------------------------------------------------- downlink ---

// serveDownlink drains the tap's PCM and turns it into 20 ms RTP packets.
func (b *bridge) serveDownlink() {
	buf := make([]byte, 8192)
	acc := make([]byte, 0, frameBytes*4)
	ulaw := make([]byte, 0, ulawPerFrame)
	pkt := make([]byte, 0, ulawPerFrame)

	for {
		n, err := b.dlConn.Read(buf)
		if err != nil {
			b.dlErr.Add(1)
			time.Sleep(20 * time.Millisecond)
			continue
		}
		b.lastDL.Store(time.Now().UnixNano())
		b.dlBytes.Add(uint64(n))
		acc = append(acc, buf[:n]...)

		for len(acc) >= frameBytes {
			b.gainMu.RLock()
			g := b.dlGain
			b.gainMu.RUnlock()

			// Record the far end before gain/encoding: the recording should be the
			// call, not the call as this browser happened to monitor it.
			if b.rec != nil {
				b.rec.WriteDown(acc[:frameBytes])
			}
			ulaw = g711.EncodePCM(acc[:frameBytes], g, ulaw)
			pkt = append(pkt[:0], ulaw...)
			if err := b.writeRTP(pkt); err != nil {
				// no peer connected yet — that is the normal idle state
				acc = acc[frameBytes:]
				continue
			}
			b.dlFrames.Add(1)
			acc = acc[frameBytes:]
		}
	}
}

func (b *bridge) writeRTP(payload []byte) error {
	b.peerMu.Lock()
	hasPeer := len(b.peers) > 0
	b.peerMu.Unlock()
	if !hasPeer {
		return fmt.Errorf("no peer")
	}

	b.txMu.Lock()
	seq, ts, ssrc := b.seq, b.ts, b.ssrc
	b.seq++
	b.ts += uint32(len(payload))
	b.txMu.Unlock()

	return b.track.WriteRTP(&rtp.Packet{
		Header: rtp.Header{
			Version:        2,
			PayloadType:    0,
			SequenceNumber: seq,
			Timestamp:      ts,
			SSRC:           ssrc,
		},
		Payload: payload,
	})
}

// ----------------------------------------------------------------- uplink ---

// removePeer releases the peer slot and its bounded uplink queue. It is safe to
// call from both ICE and PeerConnection state callbacks.
func (b *bridge) removePeer(peerID uint64, pc *webrtc.PeerConnection, reason string) {
	b.peerMu.Lock()
	if current, ok := b.peers[peerID]; ok && (pc == nil || current == pc) {
		delete(b.peers, peerID)
		delete(b.peerICE, peerID)
		if timer := b.peerDropTimer[peerID]; timer != nil {
			timer.Stop()
			delete(b.peerDropTimer, peerID)
		}
		b.peerMu.Unlock()
		b.mixer.Remove(peerID)
		log.Printf("peer %d removed (%s)", peerID, reason)
		return
	}
	if timer := b.peerDropTimer[peerID]; timer != nil {
		timer.Stop()
		delete(b.peerDropTimer, peerID)
	}
	b.peerMu.Unlock()
}

func (b *bridge) consumeUplink(peerID uint64, remote *webrtc.TrackRemote) {
	pcm := make([]byte, 0, frameBytes*4)
	for {
		pkt, _, err := remote.ReadRTP()
		if err != nil {
			log.Printf("uplink track closed: %v", err)
			return
		}
		b.gainMu.RLock()
		g := b.ulGain
		b.gainMu.RUnlock()

		pcm = g711.DecodePCM(pkt.Payload, g, pcm[:0])
		if len(pcm) == 0 {
			continue
		}
		// Do not write each peer's RTP packet straight to the modem UDP socket:
		// packets can arrive in bursts/out of order, and with two joined devices
		// their byte streams interleave. The single 20 ms mixer owns the socket.
		b.mixer.PushRTP(peerID, pkt.SequenceNumber, pkt.Timestamp, pcm)
	}
}

// runUplinkMixer is the only writer to the device's PCM UDP port. Every browser
// gets its own jitter/slack queue in uplinkMixer; this 20 ms clock aligns them,
// averages concurrent speakers and emits a single stable S16_LE frame to the tap.
func (b *bridge) runUplinkMixer() {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		b.callMu.Lock()
		active := b.callState == "0"
		b.callMu.Unlock()
		if !active || !b.tapRunning() {
			continue
		}
		frame, contributors := b.mixer.NextFrame()
		if contributors == 0 {
			continue // x16-audio pads its own empty UDP queue with silence
		}
		if b.rec != nil {
			// Store the exact mixed frame that we hand to the modem.
			b.rec.WriteUp(frame)
		}
		if _, err := b.ulConn.WriteToUDP(frame, b.ulAddr); err != nil {
			b.ulErr.Add(1)
			continue
		}
		b.ulFrames.Add(1)
		b.ulBytes.Add(uint64(len(frame)))
	}
}

// -------------------------------------------------------------- call control --

var (
	// +CLCC: <id>,<dir>,<stat>,<mode>,<mpty>[,"<number>",<type>]
	// dir 0 = mobile originated, 1 = mobile terminated; stat 0 = active,
	// 2 = dialing, 3 = alerting, 4 = incoming. The number is what the log needs
	// and what the page shows; it is absent on some networks, which is why the
	// group is optional.
	clccRe   = regexp.MustCompile(`\+CLCC:\s*(\d+),\s*(\d+),\s*(\d+)(?:,\s*\d+,\s*\d+(?:,\s*"([^"]*)",\s*(\d+))?)?`)
	numberRe = regexp.MustCompile(`^[0-9*#+]+$`)
)

// callSnap is one reading of the modem's call state.
type callSnap struct {
	have   bool
	stat   string // "0" active, "2" dialing, "3" alerting, "4" incoming, …
	dir    string // "0" outgoing, "1" incoming
	number string
}

// modemCall reads AT+CLCC and returns the first call it reports.
func (b *bridge) modemCall() (callSnap, error) {
	return b.modemCallMaybeForced(false)
}

func (b *bridge) modemCallForced() (callSnap, error) {
	return b.modemCallMaybeForced(true)
}

func (b *bridge) modemCallMaybeForced(forced bool) (callSnap, error) {
	var out string
	var err error
	if forced {
		out, err = b.atForced("AT+CLCC", 8*time.Second)
	} else {
		out, err = b.at("AT+CLCC", 8*time.Second)
	}
	// CLCC is the only command that names the call, but on this firmware it is also
	// the one that wedges: it has been seen to time out while AT+CGMM answers
	// normally. Falling back to CPAS — which reports the call MODE without the
	// number — keeps the terminal usable instead of stranding it on "unknown".
	if err != nil {
		return b.modemCallFromCPAS(forced)
	}
	if err != nil {
		return callSnap{}, err
	}
	if m := clccRe.FindStringSubmatch(out); m != nil {
		return callSnap{have: true, dir: m[2], stat: m[3], number: m[4]}, nil
	}
	return callSnap{}, nil
}

// acquireATLock joins QManager's one system-wide AT gate. qcmd, the poller and
// CGI workers all use flock(/tmp/qmanager_at.lock); direct /bin/atcmd calls that
// skip it can consume one another's responses even though atcmd_daemon itself
// serializes requests. Fail closed if the lock is absent or held past the
// command's deadline — never send an AT command outside the shared gate.
func acquireATLock(ctx context.Context, path string) (*os.File, error) {
	f, err := os.Open(path) // qcmd's documented shared lock is opened read-only
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return f, nil
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EAGAIN && err != syscall.EINTR {
			_ = f.Close()
			return nil, fmt.Errorf("flock %s: %w", path, err)
		}
		select {
		case <-ctx.Done():
			_ = f.Close()
			return nil, fmt.Errorf("waiting for shared AT lock %s: %w", path, ctx.Err())
		case <-ticker.C:
		}
	}
}

// atAlwaysAllowed are the verbs that must reach the modem even while the bridge
// has quarantined the AT path. They are exactly the ones an operator needs to get
// OUT of a bad state: end a call, answer a call, release all calls.
var atAlwaysAllowed = map[string]bool{
	"ATH":       true,
	"AT+CHUP":   true,
	"ATA":       true,
	"AT+CHLD":   true,
	"AT+CHLD=0": true,
	"AT+CHLD=1": true,
	// CPAS is the fallback state reader (see modemCallFromCPAS): it answers when
	// CLCC wedges, which is exactly when the bridge needs it most.
	"AT+CPAS": true,
}

// atQuarantine returns the command whose timeout poisoned the AT path, or "" when
// the path is healthy. The empty string is the "not quarantined" sentinel because
// atomic.Value cannot store nil.
func (b *bridge) atQuarantine() string {
	if v := b.atPoisoned.Load(); v != nil {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

// at runs one AT command through the vendor entry point and returns its payload
// with the "atcmd_receive:" framing stripped.
//
// Output goes to a temporary FILE, not a pipe, and that detail is the whole
// point: /bin/atcmd talks to atcmd_daemon, and a descendant can outlive the
// process while still holding the inherited stdout. With a pipe, Wait then blocks
// on a reader that will never see EOF — the call poller froze exactly this way,
// once, leaving the audio tap open after the far end had hung up. A file cannot
// block on a reader, so `Run` returns as soon as the child we started is gone,
// whatever it left behind.
func (b *bridge) at(cmd string, timeout time.Duration) (s string, err error) {
	return b.atMaybeForced(cmd, timeout, false)
}

// atForced sends a command even while quarantined. It exists for the two places
// that MUST talk to the modem during a quarantine: ending a call, and the
// verification CLCC that proves the call ended. Everything else stays paused.
func (b *bridge) atForced(cmd string, timeout time.Duration) (string, error) {
	return b.atMaybeForced(cmd, timeout, true)
}

func (b *bridge) atMaybeForced(cmd string, timeout time.Duration, forced bool) (s string, err error) {
	// Hanging up is the safety valve. Quarantine exists so a stuck broker is not
	// fed more polls, but refusing to send the ONE command that ends a call left
	// an operator with a ringing/active call they could not stop and a page that
	// kept insisting it was still up. These verbs are allowed through, and a
	// success among them is proof the broker is answering again, so it also
	// lifts the quarantine.
	force := forced || atAlwaysAllowed[strings.ToUpper(strings.TrimSpace(cmd))]
	b.atMu.Lock()
	defer b.atMu.Unlock()

	poisoned := b.atQuarantine()
	if poisoned != "" && !force {
		return "", fmt.Errorf("AT broker quarantined after %s timed out; refusing more commands until the broker answers again", poisoned)
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// QManager's qcmd serializes the poller, CGI requests and background workers
	// on this exact flock. The call bridge used to invoke /bin/atcmd directly
	// without joining that lock; when both polled (e.g. CLCC + CPIN/CPSI), their
	// replies could interleave on the broker and leave atcmd clients timing out
	// indefinitely. Take the same lock before every modem transaction. If QManager
	// already holds it for a long read, this caller times out without touching the
	// modem — never bypass the gate as a fallback.
	lockPath := os.Getenv("X16_AT_LOCK")
	if lockPath == "" {
		lockPath = "/tmp/qmanager_at.lock"
	}
	lock, lockErr := acquireATLock(ctx, lockPath)
	if lockErr != nil {
		return "", fmt.Errorf("shared AT lock: %w", lockErr)
	}
	defer func() {
		_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
		_ = lock.Close()
	}()

	f, ferr := os.CreateTemp("", "x16-at-")
	if ferr != nil {
		return "", fmt.Errorf("at temp file: %w", ferr)
	}
	name := f.Name()
	defer os.Remove(name)

	c := exec.CommandContext(ctx, b.atBin, cmd)
	c.Stdout = f
	c.Stderr = f
	c.Stdin = nil
	runErr := c.Run()
	_ = f.Close()
	if ctx.Err() != nil {
		// The vendor atcmd_daemon has no request timeout. Repeating a command
		// after its client times out can queue another request behind a wedged
		// one; stop issuing AT traffic from this bridge process instead. QManager's
		// own shim has a per-command blacklist for the same failure mode.
		b.atPoisoned.Store(cmd)
		log.Printf("AT broker quarantined: %s exceeded %s; no further commands will be sent until bridge recovery", cmd, timeout)
	}

	raw, _ := os.ReadFile(name)
	out := strings.ReplaceAll(string(raw), "\r", "")
	if i := strings.Index(out, "atcmd_receive:"); i >= 0 {
		out = out[i+len("atcmd_receive:"):]
	}
	out = strings.TrimSpace(out)

	if ctx.Err() != nil {
		err = fmt.Errorf("timeout after %s", timeout)
	} else if runErr != nil {
		err = runErr
	}

	// A reply — even an ERROR reply — means the broker is alive again. Clearing on
	// "we got an answer" rather than on "the command worked" is deliberate: the
	// point of the quarantine is to detect a SILENT broker, not a rejected verb.
	if out != "" && poisoned != "" {
		// atomic.Value cannot hold nil for a string type, so "" is the empty state
		// and atQuarantine() normalises it.
		b.atPoisoned.Store("")
		log.Printf("AT broker answering again (%s replied); quarantine lifted", cmd)
	}

	b.callMu.Lock()
	b.lastAT = cmd + " -> " + strings.ReplaceAll(out, "\n", " | ")
	b.callMu.Unlock()

	// A command that produced output we can use is not a failure, even if the
	// exit status was odd: atcmd exits non-zero for a stale response, and the
	// payload is still the modem's answer.
	if out != "" {
		return out, nil
	}
	return out, err
}

// modemCallState returns the modem's own view of the call: "" when there is none,
// otherwise the AT+CLCC stat code.
func (b *bridge) modemCallState() (string, error) {
	snap, err := b.modemCall()
	if err != nil {
		return "", err
	}
	return snap.stat, nil
}

// modemCallStateForced reads the call state even while the AT path is
// quarantined. Used only by hangup: "did the call actually end?" is the one
// question that outranks not feeding a stuck broker.
func (b *bridge) modemCallStateForced() (string, error) {
	snap, err := b.modemCallForced()
	if err != nil {
		return "", err
	}
	return snap.stat, nil
}

// cpasRe matches the call-mode report: 0 ready, 2 unknown, 3 ringing, 4 in call.
var cpasRe = regexp.MustCompile(`\+CPAS:\s*(\d)`)

// modemCallFromCPAS answers "is there a call?" without CLCC.
//
// CPAS has no call list and no number, so it cannot say WHICH call is up. That is
// enough to keep the state machine honest — idle vs in a call — and the number, if
// one was ever seen, is already held by the bridge.
func (b *bridge) modemCallFromCPAS(forced bool) (callSnap, error) {
	var out string
	var err error
	if forced {
		out, err = b.atForced("AT+CPAS", 5*time.Second)
	} else {
		out, err = b.at("AT+CPAS", 5*time.Second)
	}
	if err != nil {
		return callSnap{}, err
	}
	m := cpasRe.FindStringSubmatch(out)
	if m == nil {
		// Some firmware answers a bare OK when it will not report the mode. That is
		// "no information", not "no call": say so rather than inventing an idle line.
		return callSnap{}, fmt.Errorf("AT+CPAS gave no call mode: %q", strings.ReplaceAll(out, "\n", " "))
	}
	switch m[1] {
	case "0", "1": // ready / not available
		return callSnap{}, nil
	case "2", "3": // unknown / ringing or dialling
		return callSnap{have: true, stat: "3"}, nil
	case "4", "5": // in call / asleep-in-call
		return callSnap{have: true, stat: "0"}, nil
	default:
		return callSnap{}, fmt.Errorf("AT+CPAS mode %s is not a call state this bridge knows", m[1])
	}
}

// dial places a call with the modem's own ATD. The number is validated here
// rather than trusted from the browser: it is pasted into an AT command, and an
// embedded quote or semicolon would be a second command.
func (b *bridge) dial(number string) (string, error) {
	number = strings.TrimSpace(number)
	if number == "" {
		return "", fmt.Errorf("empty number")
	}
	if !numberRe.MatchString(number) {
		return "", fmt.Errorf("number contains unsupported characters")
	}
	out, err := b.at("ATD"+number+";", 12*time.Second)
	if !strings.Contains(out, "OK") {
		// One retry: the modem rejects a dial while another AT client (QManager's
		// poller) holds the single command channel.
		time.Sleep(700 * time.Millisecond)
		out, err = b.at("ATD"+number+";", 12*time.Second)
	}
	if !strings.Contains(out, "OK") {
		// Not a call, but the user asked for one and it did not happen — worth a
		// line in the history, because "I dialled and nothing happened" is exactly
		// the question a call log is opened to answer.
		if b.calls != nil {
			now := time.Now().Unix()
			b.calls.Add(CallRecord{
				Number: number, Direction: "outgoing",
				StartedAt: now, EndedAt: now, Outcome: outcomeFailed,
			})
		}
		return out, fmt.Errorf("dial rejected: %s", strings.ReplaceAll(out, "\n", " "))
	}
	b.callMu.Lock()
	b.callNum = number
	b.callAt = time.Now()
	b.callMu.Unlock()
	return out, err
}

// hangup ends the call and VERIFIES that it ended.
//
// Two things learned on this hardware:
//
//   - `ATH` is accepted and can be a no-op. It returns OK while the VoLTE call
//     stays up, which is precisely the failure mode that makes a hang-up button
//     untrustworthy: the page said OK and the far end stayed connected.
//   - `AT+CHUP` is the command that actually tears the call down here.
//
// So ATH goes first (it is the standard, and it does work on some networks),
// then the modem is asked what happened, then CHUP is used if the answer is
// still "in a call". Three rounds, then the raw responses are reported as-is.
func (b *bridge) hangup() (trace string, ended bool) {
	var out strings.Builder
	for round := 0; round < 3; round++ {
		ath, _ := b.at("ATH", 8*time.Second)
		out.WriteString("ATH: " + strings.ReplaceAll(ath, "\n", " "))
		if st, err := b.modemCallStateForced(); err == nil && st == "" {
			return out.String(), true
		}
		chup, _ := b.at("AT+CHUP", 8*time.Second)
		out.WriteString(" | AT+CHUP: " + strings.ReplaceAll(chup, "\n", " "))
		if st, err := b.modemCallStateForced(); err == nil && st == "" {
			log.Printf("hangup needed AT+CHUP (ATH returned OK but the call stayed up)")
			return out.String(), true
		}
		time.Sleep(900 * time.Millisecond)
	}
	log.Printf("hangup did not end the call after 3 rounds — modem still reports a call")
	return out.String(), false
}

// pollCall is the keeper loop: it tracks the modem's call state, owns the
// lifetime of the audio tap, and records one history entry per finished call.
//
// The two are deliberately coupled here rather than in the UI: the tap must open
// when the modem says "answered" and close when it says "gone", and the only
// component that sees both transitions is this loop. A page cannot be trusted
// with it — a browser tab that is closed mid-call must not leave a tap open.
func (b *bridge) pollCall() {
	last := ""
	var cur *CallRecord

	var lastATFailureLog time.Time
	failures := 0
	var lastProbe time.Time
	for {
		snap, err := b.modemCall()

		// While quarantined the poller is what notices the broker coming back: one
		// CLCC every 15s, and a reply lifts the quarantine (at() does that). Without
		// this the bridge stayed silent forever, and the only recovery was a manual
		// service restart.
		if q := b.atQuarantine(); q != "" && time.Since(lastProbe) >= 15*time.Second {
			lastProbe = time.Now()
			if probe, perr := b.at("AT+CLCC", 8*time.Second); perr == nil && probe != "" {
				log.Printf("AT broker probe succeeded; resuming normal polling")
			}
		}

		if err != nil {
			failures++
			// Keep the last known state and the open tap while the bus is merely
			// busy: one dropped poll is not a call that ended. Throttle the warning —
			// the loop retries every 2s, and logging each miss would make the only
			// useful signal scroll away.
			if time.Since(lastATFailureLog) >= 30*time.Second {
				log.Printf("AT+CLCC unavailable (%v); retaining last call state", err)
				lastATFailureLog = time.Now()
			}
			// Three consecutive misses (≈6s) is no longer "busy": the modem's state
			// is UNKNOWN, and saying so is the only honest option. Reporting "active"
			// here is what left a finished call on screen with a hang-up button that
			// could not work.
			if failures >= 3 && b.callQuarantineState() != "unknown" {
				b.callMu.Lock()
				was := b.callState
				b.callState = "unknown"
				b.callMu.Unlock()
				log.Printf("call state %q -> \"unknown\" (modem not answering); tap restarts paused", was)
			}
			time.Sleep(2 * time.Second)
			continue
		}
		failures = 0
		lastATFailureLog = time.Time{}
		st := snap.stat
		if !snap.have {
			st = ""
		}

		now := time.Now()

		// A call exists that we were not tracking yet: either we just dialled, or
		// it arrived on its own (an incoming call, or one placed from the vendor
		// app). CLCC's <dir> is authoritative; the page's actions are not.
		if snap.have && cur == nil {
			direction := "outgoing"
			if snap.dir == "1" {
				direction = "incoming"
			}
			cur = &CallRecord{
				Number:    snap.number,
				Direction: direction,
				StartedAt: now.Unix(),
			}
			log.Printf("call started: %s %s", direction, displayNumber(snap.number))
		}

		if snap.have {
			b.callMu.Lock()
			b.callNumber = snap.number
			b.callDir = snap.dir
			b.callMu.Unlock()
		}

		if cur != nil && snap.have {
			if snap.number != "" {
				cur.Number = snap.number
			}
			if snap.stat == "0" && cur.AnsweredAt == 0 {
				cur.AnsweredAt = now.Unix()
				if b.rec != nil {
					b.rec.Start(cur.Number, cur.Direction)
				}
			}
		}

		// The call ended: close the record with what actually happened.
		if cur != nil && !snap.have {
			cur.EndedAt = now.Unix()
			switch {
			case cur.AnsweredAt > 0:
				cur.Seconds = int(cur.EndedAt - cur.AnsweredAt)
				cur.Outcome = outcomeAnswered
			case cur.Direction == "incoming":
				cur.Outcome = outcomeMissed
			default:
				cur.Outcome = outcomeNoAnswer
			}
			if b.rec != nil {
				b.rec.Stop()
			}
			if b.calls != nil {
				rec := b.calls.Add(*cur)
				log.Printf("call ended: %s %s, %s, talk %s",
					rec.Direction, displayNumber(rec.Number), rec.Outcome,
					formatSeconds(rec.Seconds))
			}
			b.callMu.Lock()
			b.callEndedAt = cur.EndedAt
			b.lastOutcome = cur.Outcome
			b.callMu.Unlock()
			cur = nil
		}

		if st != last {
			log.Printf("call state %q -> %q", last, st)
			b.callMu.Lock()
			b.callState = st
			if st == "" {
				b.callNum = ""
			}
			b.callMu.Unlock()
			last = st
		}

		switch st {
		case "0": // active (answered)
			b.tapMu.Lock()
			if st != last && b.tapWedgeRun >= 3 {
				b.tapWedgeRun = 0
				b.tapNote = ""
			}
			b.tapMu.Unlock()
			b.ensureTap()
		default:
			b.stopTap()
		}

		// Poll fast while a call is in flight (the tap must open the moment the
		// far end answers) and slowly when idle: every AT+CLCC is serialised
		// against QManager's own poller on the single modem channel.
		b.callMu.Lock()
		idleFor := time.Since(b.callAt)
		b.callMu.Unlock()
		if st == "" && idleFor > 30*time.Second {
			time.Sleep(5 * time.Second)
		} else {
			time.Sleep(1500 * time.Millisecond)
		}
	}
}

// displayNumber keeps the log readable when the network withheld the number.
func displayNumber(n string) string {
	if strings.TrimSpace(n) == "" {
		return "(unknown number)"
	}
	return n
}

// --------------------------------------------------------------------- tap ---

func (b *bridge) callCount() int {
	if b.calls == nil {
		return 0
	}
	return b.calls.Count()
}

// callQuarantineState reads the raw call state under its lock, for the poller's
// "did this just become unknown?" check.
func (b *bridge) callQuarantineState() string {
	b.callMu.Lock()
	defer b.callMu.Unlock()
	return b.callState
}

func (b *bridge) tapRunning() bool {
	b.tapMu.Lock()
	defer b.tapMu.Unlock()
	return b.tapCmd != nil
}

func (b *bridge) ensureTap() {
	b.tapMu.Lock()
	if b.tapCmd != nil || b.tapWedgeRun >= 3 {
		b.tapMu.Unlock()
		return
	}
	if _, err := os.Stat(b.tapBin); err != nil {
		b.tapMu.Unlock()
		log.Printf("tap binary missing: %v", err)
		return
	}

	cmd := exec.Command(b.tapBin,
		"--ul-port", strconv.Itoa(b.ulPort),
		"--dl-port", strconv.Itoa(b.dlPort),
		"--dir", "remote",
		"--frame", "320",
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		b.tapMu.Unlock()
		log.Printf("tap stdout pipe: %v", err)
		return
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		b.tapMu.Unlock()
		log.Printf("tap stderr pipe: %v", err)
		return
	}
	if err := cmd.Start(); err != nil {
		b.tapMu.Unlock()
		log.Printf("tap start failed: %v", err)
		return
	}

	tl := newTapLog(audioLogPath())
	go tl.pump(stdout)
	go tl.pump(stderrPipe)
	done := make(chan struct{})
	b.tapCmd = cmd
	b.tapDone = done
	b.tapSince = time.Now()
	startedAt := b.tapSince
	b.tapMu.Unlock()

	log.Printf("tap started (pid %d) ul=%d dl=%d", cmd.Process.Pid, b.ulPort, b.dlPort)

	go func(c *exec.Cmd, done chan struct{}) {
		err := c.Wait()
		close(done)
		tl.Close()
		b.tapMu.Lock()
		if b.tapCmd == c {
			b.tapCmd = nil
			b.tapDone = nil
		}
		b.tapRestarts++
		b.tapLastExit = fmt.Sprintf("%v at %s", err, time.Now().Format("15:04:05"))
		// exit status 7 = the helper's watchdog fired: the vendor side never
		// answered the open (or the close). Repeated 7s mean alsa_daemon is
		// holding a dead client, which only a daemon restart clears — stop
		// hammering it and say so.
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 7 {
			b.tapWedgeRun++
			if b.tapWedgeRun >= 3 {
				b.tapNote = "vendor audio daemon is not answering PCMIO_Open — " +
					"run /data/webrtc/bin/zlt-webrtc.sh recover (restarts alsa.service), then redial"
			}
		} else {
			b.tapWedgeRun = 0
			b.tapNote = ""
		}
		blocked := b.tapWedgeRun >= 3
		b.tapMu.Unlock()
		log.Printf("tap exited: %v — %s", err,
			tl.sessionSummary(b.dlFrames.Load(), b.ulFrames.Load(), startedAt))

		// Restart while the call is still up: the vendor stream dies on its own
		// (read-thread timeout) and never recovers in-process.
		b.callMu.Lock()
		active := b.callState == "0"
		b.callMu.Unlock()
		// `active` is only trusted while the modem is answering. With the AT path
		// unavailable the state becomes "unknown", and restarting a PCMIO tap for a
		// call that may be gone is what turned one dead call into 17 restarts.
		if active && !blocked {
			time.Sleep(700 * time.Millisecond)
			b.ensureTap()
		} else if blocked {
			log.Printf("tap blocked: %d consecutive open timeouts — see zlt-webrtc.sh recover", b.tapWedgeRun)
		}
	}(cmd, done)
}

func (b *bridge) stopTap() {
	b.tapMu.Lock()
	cmd, done := b.tapCmd, b.tapDone
	b.tapMu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	log.Printf("stopping tap (pid %d)", cmd.Process.Pid)
	_ = cmd.Process.Signal(syscall.SIGTERM)

	// SIGTERM runs PCMIO_Close. Give the vendor client time to detach cleanly:
	// killing it after a fixed 3 s used to interrupt PCMIO_Close and leave
	// alsa_daemon holding a dead client, which made the next call's PCMIO_Open
	// block. The C helper itself has a 5 s Close watchdog; 12 s covers its
	// StopPlay (if explicitly armed), Close, and pipe drain without hanging the
	// call poller indefinitely.
	select {
	case <-done:
		return
	case <-time.After(12 * time.Second):
		log.Printf("tap did not exit after SIGTERM; sending SIGKILL as last resort")
		_ = cmd.Process.Kill()
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		log.Printf("tap process %d did not reap after SIGKILL", cmd.Process.Pid)
	}
}

func audioLogPath() string {
	if p := os.Getenv("X16_WEBRTC_AUDIO_LOG"); p != "" {
		return p
	}
	return "/data/log/x16-webrtc-audio.log"
}

// --------------------------------------------------------------------- http ---

func (b *bridge) handleOffer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST an SDP offer", http.StatusMethodNotAllowed)
		return
	}
	var offer webrtc.SessionDescription
	if err := json.NewDecoder(r.Body).Decode(&offer); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Several devices may join the same call. The remote cellular call remains
	// one leg; each browser gets its own WebRTC peer, all receive the same downlink
	// track, and their microphone PCM is mixed by runUplinkMixer. Keep a hard cap:
	// this is a one-core router, not an SFU for a meeting room.
	const maxPeers = mixMaxPeers
	b.peerMu.Lock()
	if len(b.peers)+b.pendingPeer >= maxPeers {
		b.peerMu.Unlock()
		http.Error(w, "call audio is full; maximum joined devices reached", http.StatusServiceUnavailable)
		return
	}
	b.pendingPeer++
	b.nextPeerID++
	peerID := b.nextPeerID
	b.peerMu.Unlock()

	registered := false
	defer func() {
		if !registered {
			b.peerMu.Lock()
			b.pendingPeer--
			b.peerMu.Unlock()
		}
	}()

	pc, err := b.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	sender, err := pc.AddTrack(b.track)
	if err != nil {
		_ = pc.Close()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	go func() {
		for {
			if _, _, err := sender.ReadRTCP(); err != nil {
				return
			}
		}
	}()

	if !b.mixer.Add(peerID) {
		_ = pc.Close()
		http.Error(w, "uplink mixer full", http.StatusServiceUnavailable)
		return
	}

	pc.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if remote.Kind() != webrtc.RTPCodecTypeAudio || remote.Codec().MimeType != webrtc.MimeTypePCMU {
			log.Printf("peer %d: ignoring uplink codec=%s", peerID, remote.Codec().MimeType)
			return
		}
		log.Printf("peer %d joined call audio: %s %d Hz %d ch", peerID,
			remote.Codec().MimeType, remote.Codec().ClockRate, remote.Codec().Channels)
		go b.consumeUplink(peerID, remote)
	})
	pc.OnICEConnectionStateChange(func(s webrtc.ICEConnectionState) {
		log.Printf("peer %d ICE %s", peerID, s)
		b.peerMu.Lock()
		b.peerICE[peerID] = s.String()
		if s == webrtc.ICEConnectionStateConnected || s == webrtc.ICEConnectionStateCompleted {
			if timer := b.peerDropTimer[peerID]; timer != nil {
				timer.Stop()
				delete(b.peerDropTimer, peerID)
			}
		}
		if s == webrtc.ICEConnectionStateDisconnected {
			if timer := b.peerDropTimer[peerID]; timer != nil {
				timer.Stop()
			}
			// A brief Wi-Fi handoff can report disconnected before ICE recovers.
			// Keep a 5 s grace, then free the slot and mixer if this exact peer is
			// still disconnected. This also cleans up browsers that vanish without
			// sending a polite Close (the ICE failed callback can take ~30 s).
			b.peerDropTimer[peerID] = time.AfterFunc(5*time.Second, func() {
				if pc.ICEConnectionState() == webrtc.ICEConnectionStateDisconnected ||
					pc.ICEConnectionState() == webrtc.ICEConnectionStateFailed {
					b.removePeer(peerID, pc, "ICE disconnected timeout")
					_ = pc.Close()
				}
			})
		}
		b.peerMu.Unlock()
	})
	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		log.Printf("peer %d %s", peerID, s)
		if s == webrtc.PeerConnectionStateFailed || s == webrtc.PeerConnectionStateClosed {
			b.removePeer(peerID, pc, s.String())
		}
	})

	if err = pc.SetRemoteDescription(offer); err != nil {
		b.mixer.Remove(peerID)
		_ = pc.Close()
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		b.mixer.Remove(peerID)
		_ = pc.Close()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	gather := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(answer); err != nil {
		b.mixer.Remove(peerID)
		_ = pc.Close()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	<-gather

	b.peerMu.Lock()
	b.pendingPeer--
	b.peers[peerID] = pc
	if _, ok := b.peerICE[peerID]; !ok {
		b.peerICE[peerID] = "new"
	}
	registered = true
	b.peerMu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(pc.LocalDescription())
}

func (b *bridge) aggregateICELocked() string {
	if len(b.peerICE) == 0 {
		return ""
	}
	connected, checking, failed := 0, 0, 0
	for _, state := range b.peerICE {
		switch state {
		case "connected", "completed":
			connected++
		case "checking", "new", "":
			checking++
		case "failed", "disconnected":
			failed++
		}
	}
	if connected > 0 {
		return fmt.Sprintf("connected (%d/%d)", connected, len(b.peerICE))
	}
	if checking > 0 {
		return "checking"
	}
	if failed > 0 {
		return "failed"
	}
	return "closed"
}

type stateResp struct {
	Call          string  `json:"call"`
	CallLabel     string  `json:"call_label"`
	Number        string  `json:"number"`
	CallNumber    string  `json:"call_number"`
	CallDir       string  `json:"call_dir"`
	CallEnded     int64   `json:"call_ended_at"`
	Outcome       string  `json:"last_outcome"`
	ICE           string  `json:"ice"`
	Peers         int     `json:"peers"`
	Tap           bool    `json:"tap"`
	TapNote       string  `json:"tap_note"`
	TapAge        float64 `json:"tap_age_s"`
	Restarts      int     `json:"tap_restarts"`
	TapExit       string  `json:"tap_last_exit"`
	DLFrames      uint64  `json:"dl_frames"`
	DLBytes       uint64  `json:"dl_bytes"`
	ULFrames      uint64  `json:"ul_frames"`
	ULBytes       uint64  `json:"ul_bytes"`
	DLAgeMs       int64   `json:"dl_age_ms"`
	ULGain        float64 `json:"ul_gain"`
	DLGain        float64 `json:"dl_gain"`
	CAPrint       string  `json:"ca_fingerprint"`
	Calls         int     `json:"calls_total"`
	Recording     bool    `json:"recording"`
	RecOn         bool    `json:"record_enabled"`
	Recs          int     `json:"recordings_total"`
	Contacts      int     `json:"contacts_total"`
	ATQuarantined bool    `json:"at_quarantined"`
	ATNote        string  `json:"at_note"`
	LastAT        string  `json:"last_at"`
}

var callLabels = map[string]string{
	"": "idle", "0": "active", "1": "held", "2": "dialing",
	"3": "ringing", "4": "incoming", "5": "waiting",
}

// callLabel adds the one state the modem cannot report: "ended". The bridge knows
// when a call finished and what came of it, so the page can show it for a few
// seconds instead of snapping straight back to "no call" and leaving the user
// unsure whether the call ever existed.
func (b *bridge) labelOf(state string) string {
	if state == "unknown" {
		return "unknown"
	}
	label, _, _ := b.callLabel(state)
	return label
}

func (b *bridge) callLabel(state string) (label string, endedAt int64, outcome string) {
	b.callMu.Lock()
	endedAt, outcome = b.callEndedAt, b.lastOutcome
	b.callMu.Unlock()
	if state == "" && endedAt > 0 && time.Since(time.Unix(endedAt, 0)) < 8*time.Second {
		return "ended", endedAt, outcome
	}
	return callLabels[state], endedAt, outcome
}

func (b *bridge) handleState(w http.ResponseWriter, r *http.Request) {
	b.callMu.Lock()
	st, num, lastAT := b.callState, b.callNum, b.lastAT
	callNumber, callDir, endedAt, outcome := b.callNumber, b.callDir, b.callEndedAt, b.lastOutcome
	b.callMu.Unlock()

	recording, recOn, recs, contacts := false, false, 0, 0
	if b.rec != nil {
		recording, recOn, recs = b.rec.Recording(), b.rec.Enabled(), len(b.rec.List())
	}
	if b.book != nil {
		contacts = b.book.Count()
	}

	b.peerMu.Lock()
	ice, peers := b.aggregateICELocked(), len(b.peers)
	b.peerMu.Unlock()

	b.tapMu.Lock()
	run, since, restarts, exit := b.tapCmd != nil, b.tapSince, b.tapRestarts, b.tapLastExit
	note := b.tapNote
	b.tapMu.Unlock()

	b.gainMu.RLock()
	ug, dg := b.ulGain, b.dlGain
	b.gainMu.RUnlock()

	ageMs := int64(-1)
	if v := b.lastDL.Load(); v > 0 {
		ageMs = time.Since(time.Unix(0, v)).Milliseconds()
	}
	tapAge := 0.0
	if run {
		tapAge = time.Since(since).Seconds()
	}
	atQuarantined, atNote := false, ""
	if poisoned := b.atQuarantine(); poisoned != "" {
		atQuarantined = true
		atNote = fmt.Sprintf("AT command %s timed out. Hang-up, answer and dial still reach the modem; polling paused until the broker answers again (it is probed every 15s).", poisoned)
	}

	writeJSON(w, stateResp{
		Call: st, CallLabel: b.labelOf(st), Number: num, ICE: ice,
		CallNumber: callNumber, CallDir: callDir, CallEnded: endedAt, Outcome: outcome,
		Peers: peers, Recording: recording, RecOn: recOn, Recs: recs, Contacts: contacts,
		ATQuarantined: atQuarantined, ATNote: atNote,
		Tap: run, TapNote: note, TapAge: tapAge, Restarts: restarts, TapExit: exit,
		DLFrames: b.dlFrames.Load(), DLBytes: b.dlBytes.Load(),
		ULFrames: b.ulFrames.Load(), ULBytes: b.ulBytes.Load(),
		DLAgeMs: ageMs, ULGain: ug, DLGain: dg, CAPrint: b.caPrint,
		Calls: b.callCount(), LastAT: lastAT,
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// both registers a handler under the standalone prefix (/api/...) and the
// QManager-same-origin prefix (/callapi/...). Two prefixes, one implementation:
// the page served by the QManager proxy must reach the API without a cross-origin
// request, because a QManager page at http://192.168.3.1:8080 fetching
// https://192.168.3.1:8443 would need CORS *and* a trusted certificate for a
// host it is not on. Same-origin removes both problems.
func both(mux *http.ServeMux, path string, h http.HandlerFunc) {
	wrapped := func(w http.ResponseWriter, r *http.Request) {
		// The QManager page can be opened at http://192.168.3.1:8080, where
		// /callapi does not exist, so it falls back to this listener's /api on
		// :8443 — cross-origin, hence CORS. The API carries no credentials and is
		// bound to the LAN like the rest of this device's tooling.
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.Header().Set("Access-Control-Max-Age", "600")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h(w, r)
	}
	mux.HandleFunc(path, wrapped)
	mux.HandleFunc("/callapi"+strings.TrimPrefix(path, "/api"), wrapped)
}

// bothPrefix is both() for a subtree (/api/recordings/<file>), where the path
// carries a variable part.
func bothPrefix(mux *http.ServeMux, prefix string, h http.HandlerFunc) {
	wrapped := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h(w, r)
	}
	mux.HandleFunc(prefix, wrapped)
	mux.HandleFunc("/callapi"+strings.TrimPrefix(prefix, "/api"), wrapped)
}

// serveCACert publishes the local root so a phone or laptop can install it once
// (settings → install profile / "trusted root"), after which every page served
// here — QManager included — is trusted with no warning.
func (b *bridge) serveCACert(w http.ResponseWriter, r *http.Request) {
	if b.caPath == "" {
		http.NotFound(w, r)
		return
	}
	data, err := os.ReadFile(b.caPath)
	if err != nil {
		http.Error(w, "no CA on this device", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/x-x509-ca-cert")
	w.Header().Set("Content-Disposition", `attachment; filename="zlt-x16-ca.crt"`)
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(data)
}

// apiRoutes is the whole call API, mounted wherever it is needed.
func (b *bridge) apiRoutes() http.Handler {
	mux := http.NewServeMux()
	both(mux, "/api/offer", b.handleOffer)
	both(mux, "/api/state", b.handleState)

	both(mux, "/api/call", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			Number string `json:"number"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		out, err := b.dial(body.Number)
		if err != nil {
			writeJSON(w, map[string]any{"ok": false, "error": err.Error(), "at": out})
			return
		}
		writeJSON(w, map[string]any{"ok": true, "at": out})
	})

	both(mux, "/api/hangup", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST", http.StatusMethodNotAllowed)
			return
		}
		out, ended := b.hangup()
		res := map[string]any{"ok": ended, "at": out}
		if !ended {
			res["error"] = "the modem still reports a call after ATH and AT+CHUP; the network may have ended it while the modem kept the state, or the AT broker is not answering"
		}
		writeJSON(w, res)
	})

	both(mux, "/api/dtmf", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST", http.StatusMethodNotAllowed)
			return
		}
		digit := r.URL.Query().Get("digit")
		if len(digit) != 1 || !strings.ContainsAny(digit, "0123456789*#") {
			http.Error(w, "digit must be one of 0-9 * #", http.StatusBadRequest)
			return
		}
		out, err := b.at(`AT+VTS="`+digit+`"`, 5*time.Second)
		writeJSON(w, map[string]any{"ok": err == nil && !strings.Contains(out, "ERROR"), "at": out})
	})

	both(mux, "/api/calls", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			limit := 50
			if v := r.URL.Query().Get("limit"); v != "" {
				if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
					limit = n
				}
			}
			list := []CallRecord{}
			if b.calls != nil {
				list = b.calls.List(limit)
			}
			writeJSON(w, map[string]any{"calls": list, "total": b.callCount()})
		case http.MethodDelete, http.MethodPost:
			if b.calls != nil {
				if err := b.calls.Clear(); err != nil {
					http.Error(w, err.Error(), http.StatusInternalServerError)
					return
				}
			}
			writeJSON(w, map[string]any{"ok": true})
		default:
			http.Error(w, "GET or DELETE", http.StatusMethodNotAllowed)
		}
	})

	both(mux, "/api/answer", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST", http.StatusMethodNotAllowed)
			return
		}
		out, err := b.at("ATA", 10*time.Second)
		ok := strings.Contains(out, "OK")
		writeJSON(w, map[string]any{"ok": ok, "at": out, "error": errStr(err)})
	})

	both(mux, "/api/reject", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST", http.StatusMethodNotAllowed)
			return
		}
		out, ended := b.hangup()
		writeJSON(w, map[string]any{"ok": ended, "at": out})
	})

	// ---- recordings -----------------------------------------------------
	both(mux, "/api/recordings", func(w http.ResponseWriter, r *http.Request) {
		if b.rec == nil {
			writeJSON(w, map[string]any{"recordings": []RecordingInfo{}, "total": 0, "enabled": false})
			return
		}
		list := b.rec.List()
		writeJSON(w, map[string]any{
			"recordings": list, "total": len(list), "enabled": b.rec.Enabled(),
		})
	})

	bothPrefix(mux, "/api/recordings/", func(w http.ResponseWriter, r *http.Request) {
		if b.rec == nil {
			http.NotFound(w, r)
			return
		}
		name := strings.TrimPrefix(r.URL.Path, "/api/recordings/")
		name = strings.TrimPrefix(name, "/callapi/recordings/")

		switch r.Method {
		case http.MethodDelete:
			if !b.rec.Delete(name) {
				http.Error(w, "no such recording", http.StatusNotFound)
				return
			}
			writeJSON(w, map[string]any{"ok": true})
		case http.MethodGet:
			path, ok := b.rec.PathFor(name)
			if !ok {
				http.Error(w, "no such recording", http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "audio/wav")
			w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
			http.ServeFile(w, r, path)
		default:
			http.Error(w, "GET or DELETE", http.StatusMethodNotAllowed)
		}
	})

	both(mux, "/api/record", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			On *bool `json:"on"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.On == nil {
			http.Error(w, "{\"on\": true|false}", http.StatusBadRequest)
			return
		}
		if b.rec != nil {
			b.rec.SetEnabled(*body.On)
		}
		writeJSON(w, map[string]any{"ok": true, "on": b.rec != nil && b.rec.Enabled()})
	})

	// ---- contacts -------------------------------------------------------
	both(mux, "/api/contacts", func(w http.ResponseWriter, r *http.Request) {
		if b.book == nil {
			writeJSON(w, map[string]any{"contacts": []Contact{}, "total": 0})
			return
		}
		switch r.Method {
		case http.MethodGet:
			list := b.book.List()
			writeJSON(w, map[string]any{"contacts": list, "total": len(list)})
		case http.MethodPost, http.MethodPut:
			var c Contact
			if err := json.NewDecoder(r.Body).Decode(&c); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			if strings.TrimSpace(c.Phone) == "" {
				http.Error(w, "a contact needs a phone number", http.StatusBadRequest)
				return
			}
			saved, created := b.book.Upsert(c)
			writeJSON(w, map[string]any{"ok": true, "contact": saved, "created": created})
		case http.MethodDelete:
			id, err := strconv.ParseUint(r.URL.Query().Get("id"), 10, 64)
			if err != nil {
				http.Error(w, "?id=", http.StatusBadRequest)
				return
			}
			if !b.book.Delete(id) {
				http.Error(w, "no such contact", http.StatusNotFound)
				return
			}
			writeJSON(w, map[string]any{"ok": true})
		default:
			http.Error(w, "GET, POST or DELETE", http.StatusMethodNotAllowed)
		}
	})

	// The body is the vCard text itself (Content-Type text/vcard), not a
	// multipart upload: the page can read the file and send it, and the bridge
	// stays free of a form parser.
	both(mux, "/api/contacts/import", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST", http.StatusMethodNotAllowed)
			return
		}
		if b.book == nil {
			http.Error(w, "no contact store", http.StatusInternalServerError)
			return
		}
		tmp, err := os.CreateTemp("", "x16-vcf-")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer func() {
			tmp.Close()
			os.Remove(tmp.Name())
		}()
		if _, err := io.Copy(tmp, io.LimitReader(r.Body, 32<<20)); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if _, err := tmp.Seek(0, 0); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		parsed, skipped, err := ParseVCF(tmp)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		created, updated := 0, 0
		for _, c := range parsed {
			if _, isNew := b.book.Upsert(c); isNew {
				created++
			} else {
				updated++
			}
		}
		log.Printf("vcf import: %d new, %d updated, %d skipped (no number)", created, updated, skipped)
		writeJSON(w, map[string]any{
			"ok": true, "imported": created, "updated": updated,
			"skipped": skipped, "seen": len(parsed), "total": b.book.Count(),
		})
	})

	both(mux, "/api/gain", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			Up   *float64 `json:"up"`
			Down *float64 `json:"down"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		b.gainMu.Lock()
		if body.Up != nil {
			b.ulGain = clampGain(*body.Up)
		}
		if body.Down != nil {
			b.dlGain = clampGain(*body.Down)
		}
		ug, dg := b.ulGain, b.dlGain
		b.gainMu.Unlock()
		writeJSON(w, map[string]any{"ok": true, "up": ug, "down": dg})
	})

	return mux
}

// standaloneHandler serves the bridge's own page plus the API.
func (b *bridge) standaloneHandler(api http.Handler) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(indexHTML)
	})
	mux.Handle("/api/", api)
	mux.Handle("/callapi/", api)
	mux.HandleFunc("/ca.crt", b.serveCACert)
	return mux
}

// qmHandler serves the call API at /callapi/* and hands everything else to
// QManager, which is what makes the Calls page usable: a page served over HTTPS
// is a secure context, so the browser will hand out the microphone. QManager's
// own listener (busybox httpd, no TLS) cannot provide that.
func (b *bridge) qmHandler(api http.Handler, proxy http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/callapi/") {
			api.ServeHTTP(w, r)
			return
		}
		// /ca.crt must come from us, not from QManager's docroot: it is the file
		// the user installs to make this origin trusted in the first place.
		if r.URL.Path == "/ca.crt" {
			b.serveCACert(w, r)
			return
		}
		proxy.ServeHTTP(w, r)
	})
}

func errStr(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func clampGain(v float64) float64 {
	if v < 0.1 {
		return 0.1
	}
	if v > 8 {
		return 8
	}
	return v
}

// --------------------------------------------------------------------- main ---

func main() {
	addr := flag.String("addr", ":8443", "HTTPS listen address")
	cert := flag.String("cert", "", "TLS certificate (default: <data>/etc/server.crt)")
	key := flag.String("key", "", "TLS key (default: <data>/etc/server.key)")
	dataDir := flag.String("data", "/data/webrtc", "data directory (logs are /data/log)")
	dlPort := flag.Int("dl-port", 50006, "loopback UDP port the tap sends call audio to")
	ulPort := flag.Int("ul-port", 50005, "loopback UDP port the tap takes uplink audio from")
	tapBin := flag.String("tap", "/data/webrtc/bin/x16-audio", "PCMIO tap pump binary")
	atBin := flag.String("at", "/bin/atcmd", "vendor AT command entry point")
	recordOn := flag.Bool("record", true, "record answered calls to <data>/recordings (stereo WAV: left = far end, right = browser mic)")
	recordKeep := flag.Int("record-keep", 50, "how many recordings to keep")
	plain := flag.Bool("http", false, "serve plain HTTP (getUserMedia will be refused by the browser unless the page is on localhost)")
	qmAddr := flag.String("qm-addr", ":8444", "HTTPS address that reverse-proxies QManager so its Calls page can use the microphone (empty disables)")
	qmUpstream := flag.String("qm-upstream", "http://127.0.0.1:8080", "QManager's own listener")
	lanIP := flag.String("lan-ip", "192.168.3.1", "IP address the certificate is issued for")
	genCert := flag.Bool("gen-cert", false, "generate/replace the TLS certificate and exit")
	forceCert := flag.Bool("force-cert", false, "with -gen-cert, replace a usable certificate too")
	flag.Parse()

	log.SetFlags(log.LstdFlags)
	log.SetPrefix("x16-webrtc: ")

	certPath, keyPath := *cert, *key
	if certPath == "" {
		certPath = filepath.Join(*dataDir, "etc", "server.crt")
	}
	if keyPath == "" {
		keyPath = filepath.Join(*dataDir, "etc", "server.key")
	}

	if *genCert {
		msg, err := ensureCert(certPath, keyPath, []string{*lanIP}, *forceCert)
		if err != nil {
			log.Fatalf("certificate: %v", err)
		}
		log.Printf("%s -> %s", msg, certPath)
		return
	}
	// Serve with a correct certificate even if install.sh never ran the cert
	// step: a missing cert here would only produce a silent HTTPS failure.
	if msg, err := ensureCert(certPath, keyPath, []string{*lanIP}, false); err != nil {
		log.Printf("certificate: %v", err)
	} else {
		log.Printf("certificate: %s", msg)
	}
	caPath, _ := caPaths(certPath)
	caPrint := ""
	if ca, err := loadCert(caPath); err == nil {
		caPrint = caFingerprint(ca)
	}

	b, err := newBridge(*tapBin, *atBin, *dlPort, *ulPort)
	if err != nil {
		log.Fatalf("bridge: %v", err)
	}
	b.certPath, b.caPath, b.caPrint = certPath, caPath, caPrint
	b.rec = NewRecorder(filepath.Join(*dataDir, "recordings"), *recordOn, *recordKeep)
	b.book = newContactStore(filepath.Join(*dataDir, "contacts.json"))
	b.calls = newCallLog(filepath.Join(*dataDir, "log", "calls.jsonl"), 500)
	if n := b.calls.Count(); n > 0 {
		log.Printf("call history: %d entries at %s", n, filepath.Join(*dataDir, "log", "calls.jsonl"))
	}

	go b.serveDownlink()
	go b.runUplinkMixer()
	go b.pollCall()

	api := b.apiRoutes()
	srv := &http.Server{
		Addr:              *addr,
		Handler:           b.standaloneHandler(api),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		s := <-sig
		log.Printf("%s: closing", s)
		// A wedged vendor client can make PCMIO_Close block forever, which left the
		// process alive across `systemctl restart` and left the operator with a
		// stale bridge (and a stale call state) they could not clear. Shutdown is
		// bounded: whatever has not finished in 6s is abandoned.
		go func() {
			time.Sleep(6 * time.Second)
			log.Printf("shutdown watchdog: forcing exit")
			os.Exit(0)
		}()
		b.stopTap()
		// Give the helper a moment to detach from alsa_daemon cleanly before we
		// drop the process; PCMIO_Close is what stops the vendor stream.
		time.Sleep(1200 * time.Millisecond)
		os.Exit(0)
	}()

	if *qmAddr != "" {
		up, err := url.Parse(*qmUpstream)
		if err != nil {
			log.Fatalf("qm upstream %q: %v", *qmUpstream, err)
		}
		proxy := httputil.NewSingleHostReverseProxy(up)
		// QManager's CGI scripts are shell + curl; a slow read must not be
		// reported as a dead upstream, so keep the default transport but make the
		// failure legible instead of a bare 502 body.
		proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("qm proxy %s: %v", r.URL.Path, err)
			http.Error(w, "QManager did not answer on "+*qmUpstream, http.StatusBadGateway)
		}
		qmSrv := &http.Server{
			Addr:              *qmAddr,
			Handler:           b.qmHandler(api, proxy),
			ReadHeaderTimeout: 10 * time.Second,
		}
		go func() {
			log.Printf("serving QManager over HTTPS on %s -> %s (call API at /callapi)", *qmAddr, *qmUpstream)
			if err := qmSrv.ListenAndServeTLS(certPath, keyPath); err != nil {
				log.Printf("QManager HTTPS listener stopped: %v", err)
			}
		}()
	}

	if *plain {
		log.Printf("serving HTTP on %s (page will refuse microphone access on a LAN IP)", *addr)
		log.Printf("PCM tap: udp %d<-/%d-> %s", *dlPort, *ulPort, *tapBin)
		log.Fatal(srv.ListenAndServe())
	}

	if _, err := os.Stat(certPath); err != nil {
		log.Fatalf("TLS certificate missing: %s (%v) — run the module's install.sh, which generates one", certPath, err)
	}
	log.Printf("serving HTTPS on %s (cert %s)", *addr, certPath)
	log.Printf("PCM tap: udp %d<-/%d-> %s", *dlPort, *ulPort, *tapBin)
	log.Fatal(srv.ListenAndServeTLS(certPath, keyPath))
}
