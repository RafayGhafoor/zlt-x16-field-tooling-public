// smoketest — a headless stand-in for the browser page.
//
// It performs exactly what index.html does over the wire (offer, answer, ICE),
// sends a 1 kHz tone as G.711 PCMU into the call and reports what comes back out
// of the downlink. That makes the media path testable before a browser is
// involved, and testable again after any change to the page or the bridge.
//
//	go run ./cmd/smoketest -url https://192.168.3.1:8443 -seconds 6
//	go run ./cmd/smoketest -url https://192.168.3.1:8443 -call 03154308207 -tone 0.4
//
// Exit status: 0 when the WebRTC link came up and (if a call was requested) the
// call reached the answered state with the PCM tap open.

package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"

	"x16webrtc/g711"
)

const (
	sampleRate   = 8000
	frameSamples = 160
)

var (
	baseURL   = flag.String("url", "https://192.168.3.1:8443", "bridge base URL")
	seconds   = flag.Float64("seconds", 6, "how long to run audio after the link is up")
	callTo    = flag.String("call", "", "dial this number first (and hang up at the end)")
	toneLevel = flag.Float64("tone", 0.5, "uplink tone amplitude 0..1 (0 = silence)")
	noAudio   = flag.Bool("no-audio", false, "skip media, only exercise the HTTP API")
	beeps     = flag.Bool("beeps", true, "gate the uplink tone into 0.5 s beeps so it is unmistakable on the far end")
	insecure  = flag.Bool("insecure", true, "skip TLS verification — the device ships a self-signed certificate, and a browser does the same once you accept the warning (pass -insecure=false to enforce)")
)

var httpClient = &http.Client{Timeout: 20 * time.Second}

// tlsClient mirrors what a browser does after the user accepts the
// self-signed certificate: encrypt, but do not demand a trusted chain.
func tlsClient() *http.Client {
	if !*insecure {
		return &http.Client{Timeout: 20 * time.Second}
	}
	return &http.Client{
		Timeout: 20 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}
}

type state struct {
	Call      string  `json:"call"`
	CallLabel string  `json:"call_label"`
	Tap       bool    `json:"tap"`
	TapAge    float64 `json:"tap_age_s"`
	Restarts  int     `json:"tap_restarts"`
	DLFrames  uint64  `json:"dl_frames"`
	DLBytes   uint64  `json:"dl_bytes"`
	ULFrames  uint64  `json:"ul_frames"`
	ULBytes   uint64  `json:"ul_bytes"`
	DLAgeMs   int64   `json:"dl_age_ms"`
	LastAT    string  `json:"last_at"`
}

func getState() (state, error) {
	var s state
	res, err := httpClient.Get(*baseURL + "/api/state")
	if err != nil {
		return s, err
	}
	defer res.Body.Close()
	err = json.NewDecoder(res.Body).Decode(&s)
	return s, err
}

func post(path string, body any) (map[string]any, error) {
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	res, err := httpClient.Post(*baseURL+path, "application/json", &buf)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode >= 300 {
		return nil, fmt.Errorf("%s: HTTP %d", path, res.StatusCode)
	}
	var out map[string]any
	err = json.NewDecoder(res.Body).Decode(&out)
	return out, err
}

func main() {
	flag.Parse()
	log.SetFlags(0)
	log.SetPrefix("smoketest: ")
	httpClient = tlsClient()
	if *insecure {
		log.Printf("TLS verification off (self-signed LAN certificate, as in a browser with the warning accepted)")
	}

	st, err := getState()
	if err != nil {
		log.Fatalf("bridge unreachable at %s: %v", *baseURL, err)
	}
	log.Printf("bridge ok — call=%q tap=%v restarts=%d", st.CallLabel, st.Tap, st.Restarts)

	if *noAudio {
		if *callTo != "" {
			if r, err := post("/api/call", map[string]string{"number": *callTo}); err != nil {
				log.Fatalf("dial: %v", err)
			} else {
				log.Printf("dial: %v", r)
			}
		}
		return
	}

	// --- signalling: identical to the page, PCMU only ------------------------
	media := &webrtc.MediaEngine{}
	if err := media.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType: webrtc.MimeTypePCMU, ClockRate: sampleRate, Channels: 1,
		},
		PayloadType: 0,
	}, webrtc.RTPCodecTypeAudio); err != nil {
		log.Fatalf("codec: %v", err)
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(media))

	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		log.Fatalf("peer: %v", err)
	}
	defer pc.Close()

	track, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypePCMU, ClockRate: sampleRate, Channels: 1,
	}, "smoketest-ul", "smoketest")
	if err != nil {
		log.Fatalf("track: %v", err)
	}
	if _, err = pc.AddTrack(track); err != nil {
		log.Fatalf("add track: %v", err)
	}

	var gotPackets, gotBytes int
	var gotRMS float64
	var maxRMS float64
	var lastPacket time.Time

	pc.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		log.Printf("downlink track: %s %d Hz (%d ch)", remote.Codec().MimeType,
			remote.Codec().ClockRate, remote.Codec().Channels)
		for {
			pkt, _, err := remote.ReadRTP()
			if err != nil {
				return
			}
			gotPackets++
			gotBytes += len(pkt.Payload)
			lastPacket = time.Now()

			pcm := g711.DecodePCM(pkt.Payload, 1.0, nil)
			var sum float64
			n := len(pcm) / 2
			for i := 0; i < n; i++ {
				s := int16(uint16(pcm[2*i]) | uint16(pcm[2*i+1])<<8)
				sum += float64(s) * float64(s)
			}
			if n > 0 {
				rms := math.Sqrt(sum / float64(n))
				gotRMS = rms
				if rms > maxRMS {
					maxRMS = rms
				}
			}
		}
	})

	connected := make(chan struct{})
	pc.OnICEConnectionStateChange(func(s webrtc.ICEConnectionState) {
		log.Printf("ICE %s", s)
		if s == webrtc.ICEConnectionStateConnected || s == webrtc.ICEConnectionStateCompleted {
			select {
			case <-connected:
			default:
				close(connected)
			}
		}
	})

	offer, err := pc.CreateOffer(nil)
	if err != nil {
		log.Fatalf("offer: %v", err)
	}
	gather := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(offer); err != nil {
		log.Fatalf("set local: %v", err)
	}
	<-gather

	res, err := httpClient.Post(*baseURL+"/api/offer", "application/json", bytes.NewReader(mustJSON(pc.LocalDescription())))
	if err != nil {
		log.Fatalf("offer POST: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		log.Fatalf("offer rejected: HTTP %d", res.StatusCode)
	}
	var answer webrtc.SessionDescription
	if err := json.NewDecoder(res.Body).Decode(&answer); err != nil {
		log.Fatalf("answer decode: %v", err)
	}
	if err := pc.SetRemoteDescription(answer); err != nil {
		log.Fatalf("set remote: %v", err)
	}
	log.Printf("answer applied — waiting for ICE")

	select {
	case <-connected:
		log.Printf("media connected")
	case <-time.After(15 * time.Second):
		log.Fatalf("ICE did not connect in 15 s (check UDP 50000-50100 on the LAN side)")
	}

	if *callTo != "" {
		r, err := post("/api/call", map[string]string{"number": *callTo})
		if err != nil {
			log.Fatalf("dial failed: %v", err)
		}
		log.Printf("dial %s: %v", *callTo, r)

		start := time.Now()
		answered := false
		for time.Now().Before(start.Add(70 * time.Second)) {
			st, err := getState()
			if err == nil {
				fmt.Printf("  state=%-8s tap=%-5v dl=%-6d ul=%d\n",
					st.CallLabel, st.Tap, st.DLFrames, st.ULFrames)
				if st.Call == "0" && st.Tap {
					answered = true
					break
				}
				if st.Call == "" && time.Since(start) > 20*time.Second {
					log.Printf("call never registered with the modem — giving up")
					break
				}
			}
			time.Sleep(2 * time.Second)
		}
		if !answered {
			log.Printf("call did not reach answered+tap; audio will be sent anyway")
		} else {
			log.Printf("call answered and PCM tap is open — sending audio now")
		}
	}

	// --- media: 1 kHz tone at 8 kHz, 20 ms packets ---------------------------
	stop := time.After(time.Duration(*seconds * float64(time.Second)))
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()

	var seq uint16
	var ts uint32
	phase := 0.0
	step := 2 * math.Pi * 1000 / sampleRate
	sent := 0

	log.Printf("sending %.0f%% 1 kHz tone for %.1fs; downlink will be summarised", *toneLevel*100, *seconds)
	for {
		select {
		case <-stop:
			goto done
		case <-ticker.C:
			level := *toneLevel
			if *beeps && (sent/25)%2 == 1 { // 25 packets = 0.5 s
				level = 0
			}
			pcm := make([]byte, frameSamples*2)
			for i := 0; i < frameSamples; i++ {
				v := math.Sin(phase) * 32767 * level
				s := int16(v)
				pcm[2*i] = byte(uint16(s))
				pcm[2*i+1] = byte(uint16(s) >> 8)
				phase += step
			}
			payload := g711.EncodePCM(pcm, 1.0, nil)
			if err := track.WriteRTP(&rtp.Packet{
				Header: rtp.Header{
					Version: 2, PayloadType: 0, SequenceNumber: seq,
					Timestamp: ts, SSRC: 0x534d4f4b,
				},
				Payload: payload,
			}); err == nil {
				sent++
			}
			seq++
			ts += frameSamples
		}
	}

done:
	st, _ = getState()
	ageText := "never"
	if !lastPacket.IsZero() {
		ageText = time.Since(lastPacket).Round(time.Millisecond).String() + " ago"
	}
	log.Printf("uplink sent: %d packets (%.1f s)", sent, float64(sent)*0.02)
	log.Printf("downlink received: %d packets, %d bytes, last packet %s", gotPackets, gotBytes, ageText)
	log.Printf("downlink level: last RMS %.0f, peak RMS %.0f (0 = silence)", gotRMS, maxRMS)
	log.Printf("bridge counters: dl_frames=%d dl_bytes=%d ul_frames=%d ul_bytes=%d tap_restarts=%d",
		st.DLFrames, st.DLBytes, st.ULFrames, st.ULBytes, st.Restarts)
	if st.LastAT != "" {
		log.Printf("last AT: %s", st.LastAT)
	}

	if *callTo != "" {
		if r, err := post("/api/hangup", nil); err == nil {
			log.Printf("hangup: %v", r)
		} else {
			log.Printf("hangup failed: %v", err)
		}
	}

	switch {
	case gotPackets == 0:
		log.Printf("RESULT: no downlink — the call audio tap is not delivering (expected when no call is up)")
		os.Exit(2)
	case maxRMS < 1:
		log.Printf("RESULT: downlink packets present but silent (tap open, nothing to hear)")
	default:
		log.Printf("RESULT: two-way media path verified")
	}
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		log.Fatalf("json: %v", err)
	}
	return b
}
