package main

import (
	"os"
	"strings"
	"testing"
)

const sampleVCF = "BEGIN:VCARD\r\n" +
	"VERSION:3.0\r\n" +
	"FN:Alice Example\r\n" +
	"ORG:Example Ltd\r\n" +
	"TEL;TYPE=CELL:+92 315 4308207\r\n" +
	"EMAIL:alice@example.com\r\n" +
	"END:VCARD\r\n" +
	"BEGIN:VCARD\r\n" +
	"VERSION:3.0\r\n" +
	"N:Smith;Bob;;;\r\n" +
	"TEL;TYPE=HOME:0092 300 1112223\r\n" +
	"END:VCARD\r\n" +
	"BEGIN:VCARD\r\n" +
	"FN:No Number Here\r\n" +
	"EMAIL:nobody@example.com\r\n" +
	"END:VCARD\r\n" +
	"BEGIN:VCARD\r\n" +
	"VERSION:2.1\r\n" +
	"FN:Folded Person\r\n" +
	"TEL;CELL:03154308\r\n" +
	" 207\r\n" +
	"END:VCARD\r\n"

func writeTemp(t *testing.T, body string) *os.File {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "*.vcf")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(body); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestParseVCF(t *testing.T) {
	f := writeTemp(t, sampleVCF)
	defer f.Close()

	parsed, skipped, err := ParseVCF(f)
	if err != nil {
		t.Fatal(err)
	}
	if skipped != 1 {
		t.Fatalf("skipped %d contacts without a number, want 1", skipped)
	}
	if len(parsed) != 3 {
		t.Fatalf("parsed %d contacts, want 3: %+v", len(parsed), parsed)
	}
	if parsed[0].Name != "Alice Example" || parsed[0].Phone != "+92 315 4308207" || parsed[0].Company != "Example Ltd" {
		t.Fatalf("first card wrong: %+v", parsed[0])
	}
	if parsed[1].Name != "Bob Smith" {
		t.Fatalf("N: fallback wrong: %q", parsed[1].Name)
	}
	// A folded TEL line must be reassembled, not truncated at the wrap.
	if strings.TrimSpace(parsed[2].Phone) != "03154308207" {
		t.Fatalf("folded TEL not joined: %q", parsed[2].Phone)
	}
}

func TestContactsUpsertAndLookup(t *testing.T) {
	dir := t.TempDir()
	s := newContactStore(dir + "/contacts.json")

	a, created := s.Upsert(Contact{Name: "Alice", Phone: "+92 315 4308207", Source: "vcf"})
	if !created || a.ID == 0 {
		t.Fatal("first upsert should create")
	}
	// Same number, different formatting: must merge, not duplicate.
	if _, created := s.Upsert(Contact{Name: "Alice B", Phone: "03154308207", Source: "vcf"}); created {
		t.Fatal("the same number was inserted twice")
	}
	if got := s.Count(); got != 1 {
		t.Fatalf("count = %d, want 1", got)
	}

	// Lookup matches on the trailing digits, which is what makes a local-format
	// contact resolve an internationally formatted caller id.
	if c, ok := s.Lookup("+923154308207"); !ok || c.Name != "Alice B" {
		t.Fatalf("lookup failed: %+v %v", c, ok)
	}

	// Persistence: a new store reads the same book.
	if got := newContactStore(dir + "/contacts.json").Count(); got != 1 {
		t.Fatalf("reloaded %d contacts, want 1", got)
	}
}

func TestNormalizePhone(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"+92 315 4308207", "154308207"},
		{"0092-315-4308207", "154308207"},
		{"03154308207", "154308207"},
		{"12345", "12345"},
		{"", ""},
	} {
		if got := normalizePhone(tc.in); got != tc.want {
			t.Errorf("normalizePhone(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
