package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"

	"x16webrtc/g711"
)

// This is an integration test, not a component mock: it creates two real Pion
// PeerConnections, negotiates the bridge's real HTTP SDP endpoint twice, waits
// for ICE, and verifies both peers remain registered at once. No modem, call,
// microphone, or network access outside loopback is involved.
func TestTwoWebRTCPeersCanJoinOneCallBridge(t *testing.T) {
	b, err := newBridge("/does/not/need/to/exist", "/bin/false", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer b.ulConn.Close()
	defer b.dlConn.Close()

	server := httptest.NewServer(b.standaloneHandler(b.apiRoutes()))
	defer server.Close()

	first := newLocalPCMUClient(t, server.URL)
	defer first.Close()
	second := newLocalPCMUClient(t, server.URL)
	defer second.Close()

	if got := waitPeerCount(t, server.URL, 2); got != 2 {
		t.Fatalf("joined peers=%d, want 2", got)
	}
	if got := b.mixer.Count(); got != 2 {
		t.Fatalf("uplink mixer peers=%d, want 2", got)
	}

	// Send one downlink packet from the shared modem track; both browsers must
	// receive it. This catches the common "map accepts two but the track is still
	// bound to the latest peer only" regression.
	if err := b.writeRTP(bytes.Repeat([]byte{0xff}, frameSamples)); err != nil {
		t.Fatalf("shared downlink WriteRTP: %v", err)
	}
	waitReceived(t, first.gotMedia)
	waitReceived(t, second.gotMedia)

	// Each microphone sends one PCMU frame. The server-side mixer should combine
	// them into a single frame instead of letting the two UDP streams interleave.
	first.sendPCM(t, 1200)
	second.sendPCM(t, 3000)
	deadline := time.Now().Add(2 * time.Second)
	var mixed []byte
	var contributors int
	for time.Now().Before(deadline) {
		mixed, contributors = b.mixer.NextFrame()
		if contributors == 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if contributors != 2 {
		t.Fatalf("uplink mixer contributors=%d, want 2", contributors)
	}
	if got := sampleAt(mixed, 0); got < 1500 || got > 2500 {
		t.Fatalf("mixed uplink sample=%d, want average of two sources near 2100", got)
	}

	// Closing one browser must not evict the other one.
	_ = first.Close()
	if got := waitPeerCount(t, server.URL, 1); got != 1 {
		t.Fatalf("after first peer left: peers=%d, want 1", got)
	}
	if got := b.mixer.Count(); got != 1 {
		t.Fatalf("after first peer left: mixer peers=%d, want 1", got)
	}
}

type pcClient struct {
	pc       *webrtc.PeerConnection
	track    *webrtc.TrackLocalStaticRTP
	gotMedia chan struct{}
	seq      uint16
	ts       uint32
}

func waitReceived(t *testing.T, got <-chan struct{}) {
	t.Helper()
	select {
	case <-got:
	case <-time.After(2 * time.Second):
		t.Fatal("peer did not receive the shared downlink RTP packet")
	}
}

func (c *pcClient) sendPCM(t *testing.T, sample int16) {
	t.Helper()
	pcm := make([]byte, frameSamples*2)
	for i := 0; i < frameSamples; i++ {
		binary.LittleEndian.PutUint16(pcm[i*2:], uint16(sample))
	}
	payload := g711.EncodePCM(pcm, 1, nil)
	if err := c.track.WriteRTP(&rtp.Packet{
		Header:  rtp.Header{Version: 2, PayloadType: 0, SequenceNumber: c.seq, Timestamp: c.ts, SSRC: uint32(c.seq) + 1},
		Payload: payload,
	}); err != nil {
		t.Fatalf("browser test mic WriteRTP: %v", err)
	}
	c.seq++
	c.ts += frameSamples
}

func (c *pcClient) Close() error {
	if c == nil || c.pc == nil {
		return nil
	}
	return c.pc.Close()
}

func newLocalPCMUClient(t *testing.T, baseURL string) *pcClient {
	t.Helper()
	media := &webrtc.MediaEngine{}
	if err := media.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType: webrtc.MimeTypePCMU, ClockRate: 8000, Channels: 1,
		},
		PayloadType: 0,
	}, webrtc.RTPCodecTypeAudio); err != nil {
		t.Fatal(err)
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(media))
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	track, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypePCMU, ClockRate: 8000, Channels: 1,
	}, "integration-uplink", "integration")
	if err != nil {
		pc.Close()
		t.Fatal(err)
	}
	if _, err := pc.AddTrack(track); err != nil {
		pc.Close()
		t.Fatal(err)
	}
	gotMedia := make(chan struct{})
	pc.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if _, _, err := remote.ReadRTP(); err == nil {
			select {
			case <-gotMedia:
			default:
				close(gotMedia)
			}
		}
	})
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		pc.Close()
		t.Fatal(err)
	}
	gather := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(offer); err != nil {
		pc.Close()
		t.Fatal(err)
	}
	select {
	case <-gather:
	case <-time.After(5 * time.Second):
		pc.Close()
		t.Fatal("local ICE gathering timed out")
	}

	body, err := json.Marshal(pc.LocalDescription())
	if err != nil {
		pc.Close()
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/api/offer", bytes.NewReader(body))
	if err != nil {
		pc.Close()
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		pc.Close()
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		pc.Close()
		t.Fatalf("offer response: HTTP %d", resp.StatusCode)
	}
	var answer webrtc.SessionDescription
	if err := json.NewDecoder(resp.Body).Decode(&answer); err != nil {
		pc.Close()
		t.Fatal(err)
	}
	if err := pc.SetRemoteDescription(answer); err != nil {
		pc.Close()
		t.Fatal(err)
	}

	connected := make(chan struct{})
	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		if s == webrtc.PeerConnectionStateConnected {
			select {
			case <-connected:
			default:
				close(connected)
			}
		}
	})
	select {
	case <-connected:
	case <-time.After(10 * time.Second):
		state := pc.ConnectionState()
		pc.Close()
		t.Fatalf("local ICE failed to connect: peer state=%s", state)
	}
	return &pcClient{pc: pc, track: track, gotMedia: gotMedia}
}

func waitPeerCount(t *testing.T, base string, want int) int {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(base + "/api/state")
		if err == nil {
			var state map[string]any
			_ = json.NewDecoder(resp.Body).Decode(&state)
			resp.Body.Close()
			if n, ok := state["peers"].(float64); ok && int(n) == want {
				return int(n)
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	resp, err := http.Get(base + "/api/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var state map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&state)
	if n, ok := state["peers"].(float64); ok {
		return int(n)
	}
	return -1
}
