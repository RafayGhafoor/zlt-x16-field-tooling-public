// contacts.go — the address book, and the vCard import that fills it.
//
// Why the device and not the browser: a phone book that only exists in one
// browser's localStorage is lost the first time somebody opens the UI on a
// phone. It lives next to the call log (/data/webrtc/contacts.json), so the
// dashboard, the calls page and any later surface see the same book, and the
// call log can be read by name instead of by number.
//
// The vCard parser is deliberately small: FN / N / ORG / TEL / EMAIL, which is
// what an export from iOS, Android, Google Contacts or Thunderbird actually
// contains. It is line-folding aware (vCard wraps long lines with a leading
// space) because a folded TEL line is otherwise silently dropped, and it accepts
// both 2.1 (TEL;CELL:123) and 3.0/4.0 (TEL;TYPE=CELL:123) forms.

package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

type Contact struct {
	ID      uint64 `json:"id"`
	Name    string `json:"name"`
	Company string `json:"company"`
	Phone   string `json:"phone"`
	Email   string `json:"email"`
	// Source remembers where the row came from ("vcf" or "manual"), which is what
	// makes a re-import understandable rather than mysterious.
	Source string `json:"source"`
}

type contactStore struct {
	mu       sync.RWMutex
	path     string
	contacts []Contact
	nextID   uint64
}

func newContactStore(path string) *contactStore {
	s := &contactStore{path: path}
	s.load()
	return s
}

func (s *contactStore) load() {
	b, err := os.ReadFile(s.path)
	if err != nil {
		return
	}
	var list []Contact
	if err := json.Unmarshal(b, &list); err != nil {
		return
	}
	s.contacts = list
	for _, c := range list {
		if c.ID >= s.nextID {
			s.nextID = c.ID + 1
		}
	}
}

func (s *contactStore) persistLocked() {
	_ = os.MkdirAll(filepath.Dir(s.path), 0o755)
	b, err := json.MarshalIndent(s.contacts, "", "  ")
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return
	}
	_ = os.Rename(tmp, s.path)
}

func (s *contactStore) List() []Contact {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Contact, len(s.contacts))
	copy(out, s.contacts)
	sort.SliceStable(out, func(i, j int) bool {
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out
}

func (s *contactStore) Count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.contacts)
}

// normalizePhone reduces a number to comparable digits. Numbers arrive in every
// shape: "+92 315 4308207", "0092315…", "03154308207". The last 9 digits are what
// get compared, which is what makes a local-format contact match an
// internationally formatted call log entry.
func normalizePhone(p string) string {
	var b strings.Builder
	for _, r := range p {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	d := b.String()
	if len(d) > 9 {
		return d[len(d)-9:]
	}
	return d
}

// Lookup returns the contact whose number ends with the same digits as `number`.
func (s *contactStore) Lookup(number string) (Contact, bool) {
	want := normalizePhone(number)
	if want == "" {
		return Contact{}, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, c := range s.contacts {
		if normalizePhone(c.Phone) == want {
			return c, true
		}
	}
	return Contact{}, false
}

// Upsert inserts or merges by phone number. Importing the same export twice must
// not double the book, and a hand-edited name must not be lost — so an existing
// row keeps its name unless the incoming one is non-empty and different, and new
// fields fill in blanks.
func (s *contactStore) Upsert(c Contact) (Contact, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := normalizePhone(c.Phone)
	if key != "" {
		for i := range s.contacts {
			if normalizePhone(s.contacts[i].Phone) == key {
				existing := &s.contacts[i]
				if c.Name != "" {
					existing.Name = c.Name
				}
				if c.Company != "" {
					existing.Company = c.Company
				}
				if c.Email != "" {
					existing.Email = c.Email
				}
				if c.Phone != "" {
					existing.Phone = c.Phone
				}
				existing.Source = c.Source
				s.persistLocked()
				return *existing, false
			}
		}
	}

	s.nextID++
	c.ID = s.nextID
	if c.Source == "" {
		c.Source = "manual"
	}
	s.contacts = append(s.contacts, c)
	s.persistLocked()
	return c, true
}

func (s *contactStore) Delete(id uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, c := range s.contacts {
		if c.ID == id {
			s.contacts = append(s.contacts[:i], s.contacts[i+1:]...)
			s.persistLocked()
			return true
		}
	}
	return false
}

func (s *contactStore) Clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.contacts = nil
	s.persistLocked()
}

// ------------------------------------------------------------- vcf import ---

// ParseVCF reads vCards and returns the contacts it found.
func ParseVCF(r *os.File) ([]Contact, int, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)

	// Folding first, parsing second. A continuation line belongs to the line
	// BEFORE it, so the lines have to be joined before any property is read —
	// doing it inline is what silently truncated a wrapped TEL and lost the last
	// digits of the number.
	var lines []string
	var cur string
	for sc.Scan() {
		raw := strings.TrimRight(sc.Text(), "\r")
		if len(raw) > 0 && (raw[0] == ' ' || raw[0] == '\t') {
			cur += raw[1:]
			continue
		}
		if cur != "" {
			lines = append(lines, cur)
		}
		cur = raw
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	if err := sc.Err(); err != nil {
		return nil, 0, err
	}

	var out []Contact
	skipped := 0
	var c *Contact

	flush := func() {
		if c == nil {
			return
		}
		if strings.TrimSpace(c.Name) == "" && (c.Company != "" || c.Email != "") {
			c.Name = c.Company
		}
		if strings.TrimSpace(c.Name) == "" && c.Phone != "" {
			c.Name = c.Phone
		}
		if strings.TrimSpace(c.Phone) == "" {
			skipped++ // a contact with no number cannot be dialled or matched
		} else {
			c.Source = "vcf"
			out = append(out, *c)
		}
		c = nil
	}

	for _, line := range lines {
		upper := strings.ToUpper(line)
		switch {
		case upper == "BEGIN:VCARD":
			c = &Contact{}
		case upper == "END:VCARD":
			flush()
		case c == nil:
			// anything before BEGIN:VCARD — ignore
		case strings.HasPrefix(upper, "FN:"), strings.HasPrefix(upper, "FN;"):
			c.Name = strings.TrimSpace(vcardValue(line))
		case strings.HasPrefix(upper, "N:"), strings.HasPrefix(upper, "N;"):
			if c.Name == "" {
				// N is "Family;Given;Middle;Prefix;Suffix"
				var parts []string
				for _, p := range strings.Split(vcardValue(line), ";") {
					if p = strings.TrimSpace(p); p != "" {
						parts = append(parts, p)
					}
				}
				switch len(parts) {
				case 0:
				case 1:
					c.Name = parts[0]
				default:
					c.Name = strings.TrimSpace(parts[1] + " " + parts[0])
				}
			}
		case strings.HasPrefix(upper, "ORG:"), strings.HasPrefix(upper, "ORG;"):
			c.Company = strings.TrimSpace(strings.Split(vcardValue(line), ";")[0])
		case strings.HasPrefix(upper, "TEL"):
			if c.Phone == "" {
				c.Phone = strings.TrimSpace(vcardValue(line))
			}
		case strings.HasPrefix(upper, "EMAIL"):
			if c.Email == "" {
				c.Email = strings.TrimSpace(vcardValue(line))
			}
		}
	}
	if c != nil { // a file that forgot END:VCARD
		flush()
	}
	return out, skipped, nil
}

// vcardValue returns everything after the first unescaped colon.
func vcardValue(line string) string {
	// A colon inside a parameter (rare, e.g. quoted values) would confuse a naive
	// split; parameters never contain a bare colon in practice, so the first one
	// is the separator.
	if i := strings.Index(line, ":"); i >= 0 {
		v := line[i+1:]
		v = strings.ReplaceAll(v, `\,`, ",")
		v = strings.ReplaceAll(v, `\;`, ";")
		v = strings.ReplaceAll(v, `\n`, "\n")
		return v
	}
	return ""
}
