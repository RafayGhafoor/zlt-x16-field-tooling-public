// uplink_mixer.go — reorder, align and combine browser mic tracks into one modem uplink.
//
// A single RTP source was enough while the bridge replaced its peer on every
// offer. Now multiple devices can join the same call. Writing their RTP packets
// directly to the shared UDP socket makes packets interleave; consuming every
// packet in arrival order also turns one LAN reorder into a syllable of static.
//
// Each peer feeds decoded 8 kHz S16_LE samples into its own bounded RTP reorder
// queue. One 20 ms clock drains those queues, waits up to 40 ms for a missing
// sequence number, pads a genuinely lost packet with silence, averages concurrent
// talkers (so two voices do not clip), and emits ONE 160-sample frame. One-core
// budget: max four peers, four 20 ms frames of slack per peer, <12 kB total.

package main

import (
	"encoding/binary"
	"math"
	"sort"
	"sync"
	"time"
)

const (
	mixRingSamples = frameSamples * 8 // 160 ms jitter/slack per remote peer
	mixMaxPeers    = 4
	mixReorderWait = 40 * time.Millisecond
	mixMaxGap      = 50 // refuse to buffer a sequence jump longer than 1 second
)

type jitterPacket struct {
	timestamp uint32
	samples   []int16
}

type uplinkSource struct {
	mu sync.Mutex

	packets  map[uint16]jitterPacket
	nextSeq  uint16
	nextTS   uint32
	started  bool
	gapSince time.Time

	samples []int16
	off     int

	dropped uint64
	reorder uint64
	lost    uint64
}

// uplinkMixer is safe for OnTrack reader goroutines and the single 20 ms writer.
type uplinkMixer struct {
	mu        sync.Mutex
	sources   map[uint64]*uplinkSource
	synthetic map[uint64]uint16 // used only by the unit-test/direct PCM helper
}

func newUplinkMixer() *uplinkMixer {
	return &uplinkMixer{
		sources:   make(map[uint64]*uplinkSource),
		synthetic: make(map[uint64]uint16),
	}
}

func (m *uplinkMixer) Add(id uint64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.sources[id]; ok {
		return true
	}
	if len(m.sources) >= mixMaxPeers {
		return false
	}
	m.sources[id] = &uplinkSource{packets: make(map[uint16]jitterPacket), samples: make([]int16, 0, mixRingSamples)}
	return true
}

func (m *uplinkMixer) Remove(id uint64) {
	m.mu.Lock()
	delete(m.sources, id)
	delete(m.synthetic, id)
	m.mu.Unlock()
}

// PushRTP accepts a decoded PCMU packet and retains its sequence/timestamp for
// reordering. Duplicate and already-played packets are discarded.
func (m *uplinkMixer) PushRTP(id uint64, seq uint16, timestamp uint32, pcm []byte) {
	m.mu.Lock()
	s := m.sources[id]
	m.mu.Unlock()
	if s == nil || len(pcm) < 2 {
		return
	}

	decoded := make([]int16, len(pcm)/2)
	for i := range decoded {
		decoded[i] = int16(binary.LittleEndian.Uint16(pcm[i*2:]))
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.started {
		s.started = true
		s.nextSeq = seq
		s.nextTS = timestamp
	}
	delta := int16(seq - s.nextSeq) // signed modular distance handles 16-bit wrap
	if delta < 0 {
		s.dropped++ // late packet: playout already advanced past it
		return
	}
	if delta > mixMaxGap {
		// A sender restart / timestamp discontinuity: discard stale reorder state
		// and rebase rather than buffering seconds of old audio.
		s.packets = make(map[uint16]jitterPacket)
		s.samples = s.samples[:0]
		s.off = 0
		s.nextSeq = seq
		s.nextTS = timestamp
		s.gapSince = time.Time{}
		delta = 0
	}
	if _, exists := s.packets[seq]; exists {
		s.dropped++
		return
	}
	if delta > 0 {
		s.reorder++
	}
	s.packets[seq] = jitterPacket{timestamp: timestamp, samples: decoded}
}

// Push is the deterministic, sequential helper used by unit tests. Production
// RTP readers call PushRTP so packet sequence and timestamp are preserved.
func (m *uplinkMixer) Push(id uint64, pcm []byte) {
	m.mu.Lock()
	seq := m.synthetic[id]
	m.synthetic[id] = seq + 1
	m.mu.Unlock()
	m.PushRTP(id, seq, uint32(seq)*frameSamples, pcm)
}

func appendSilence(dst []int16, count int) []int16 {
	if count <= 0 {
		return dst
	}
	if count > mixRingSamples {
		count = mixRingSamples
	}
	return append(dst, make([]int16, count)...)
}

func (s *uplinkSource) drain(now time.Time) {
	for {
		packet, ok := s.packets[s.nextSeq]
		if ok {
			// Keep the RTP timestamp cadence too: a missing packet whose sequence
			// number was skipped gets an exact silence span where it belonged.
			if packet.timestamp != s.nextTS {
				gap := int32(packet.timestamp - s.nextTS)
				if gap > 0 && gap <= mixRingSamples {
					s.samples = appendSilence(s.samples, int(gap))
					s.lost++
				}
			}
			s.samples = append(s.samples, packet.samples...)
			if len(s.samples)-s.off > mixRingSamples {
				drop := len(s.samples) - s.off - mixRingSamples
				s.off += drop
				s.dropped++
			}
			s.nextTS = packet.timestamp + uint32(len(packet.samples))
			delete(s.packets, s.nextSeq)
			s.nextSeq++
			s.gapSince = time.Time{}
			continue
		}
		if len(s.packets) == 0 {
			return
		}

		// Find the nearest packet ahead of the missing sequence. Wait briefly for
		// Wi-Fi reordering; after 40 ms, represent the gap as silence and resume.
		seqs := make([]uint16, 0, len(s.packets))
		for seq := range s.packets {
			d := int16(seq - s.nextSeq)
			if d > 0 {
				seqs = append(seqs, seq)
			}
		}
		if len(seqs) == 0 {
			// All buffered packets are behind (wrap/reset); discard and let the next
			// arrival establish a fresh sequence base.
			s.packets = make(map[uint16]jitterPacket)
			return
		}
		sort.Slice(seqs, func(i, j int) bool { return int16(seqs[i]-s.nextSeq) < int16(seqs[j]-s.nextSeq) })
		if s.gapSince.IsZero() {
			s.gapSince = now
			return
		}
		if now.Sub(s.gapSince) < mixReorderWait && len(seqs) < 3 {
			return
		}
		future := s.packets[seqs[0]]
		gap := int32(future.timestamp - s.nextTS)
		if gap <= 0 || gap > mixRingSamples {
			gap = frameSamples * int32(int16(seqs[0]-s.nextSeq))
		}
		s.samples = appendSilence(s.samples, int(gap))
		s.lost++
		s.nextSeq = seqs[0]
		s.nextTS = future.timestamp
		s.gapSince = time.Time{}
	}
}

func (s *uplinkSource) takeFrame(now time.Time) []int16 {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.drain(now)
	out := make([]int16, frameSamples)
	n := len(s.samples) - s.off
	if n > frameSamples {
		n = frameSamples
	}
	// Never consume a half-frame. Browsers can packetize PCMU at 10 ms as well
	// as 20 ms; dropping a lone 80-sample packet and padding it with silence was
	// the exact shape of intermittent "robotic" uplink. Keep the samples until a
	// complete 20 ms phone frame is available, then resample-by-framing only.
	if n < frameSamples {
		return out
	}
	copy(out, s.samples[s.off:s.off+frameSamples])
	s.off += frameSamples
	if s.off >= frameSamples*4 && s.off*2 >= len(s.samples) {
		copy(s.samples, s.samples[s.off:])
		s.samples = s.samples[:len(s.samples)-s.off]
		s.off = 0
	}
	return out
}

// NextFrame returns the next mono PCM frame and the number of sources that
// actually carried non-silent signal in it. Sources without enough queued media
// are padded with silence; this prevents a slow/muted peer from shifting the
// cadence of every other participant.
func (m *uplinkMixer) NextFrame() ([]byte, int) {
	m.mu.Lock()
	sources := make([]*uplinkSource, 0, len(m.sources))
	for _, s := range m.sources {
		sources = append(sources, s)
	}
	m.mu.Unlock()

	if len(sources) == 0 {
		return make([]byte, frameBytes), 0
	}

	var mix [frameSamples]int64
	contributors := 0
	now := time.Now()
	for _, s := range sources {
		frame := s.takeFrame(now)
		// Muted / silent tracks still send packets. Do not divide their silence
		// into every other participant's voice (two connected but one muted should
		// sound like one person, not half-volume).
		var energy int64
		for _, sample := range frame {
			v := int64(sample)
			if v < 0 {
				v = -v
			}
			energy += v
		}
		if energy < 160*24 { // mean magnitude < 24 -> treat codec comfort noise as silence
			continue
		}
		contributors++
		for i, sample := range frame {
			mix[i] += int64(sample)
		}
	}

	out := make([]byte, frameBytes)
	if contributors == 0 {
		return out, 0
	}
	for i, sum := range mix {
		v := sum / int64(contributors)
		if v > math.MaxInt16 {
			v = math.MaxInt16
		} else if v < math.MinInt16 {
			v = math.MinInt16
		}
		binary.LittleEndian.PutUint16(out[i*2:], uint16(int16(v)))
	}
	return out, contributors
}

func (m *uplinkMixer) Count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.sources)
}
