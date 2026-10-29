package main

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func writeFakeAT(t *testing.T, body string) (script, calls string) {
	t.Helper()
	dir := t.TempDir()
	script = filepath.Join(dir, "fake-atcmd")
	calls = filepath.Join(dir, "calls.log")
	content := "#!/bin/sh\n" +
		"echo \"$1\" >> \"" + calls + "\"\n" + body + "\n"
	if err := os.WriteFile(script, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
	return script, calls
}

func TestBridgeATUsesQManagerFlockAndFailsClosed(t *testing.T) {
	lockPath := filepath.Join(t.TempDir(), "qmanager_at.lock")
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o666)
	if err != nil {
		t.Fatal(err)
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	t.Setenv("X16_AT_LOCK", lockPath)
	script, calls := writeFakeAT(t, "printf 'atcmd_receive:\\n+CLCC: 1,0,0,0,0,\\\"123\\\",129\\nOK\\n'")
	b := &bridge{atBin: script}

	_, err = b.at("AT+CLCC", 120*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "shared AT lock") {
		t.Fatalf("expected the bridge request to time out on qcmd's lock, got %v", err)
	}
	if _, statErr := os.Stat(calls); !os.IsNotExist(statErr) {
		t.Fatal("test setup error: fake atcmd unexpectedly ran before the shared lock")
	}

	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	out, err := b.at("AT+CLCC", time.Second)
	if err != nil {
		t.Fatalf("bridge failed to use the released shared lock: %v", err)
	}
	if !strings.Contains(out, "+CLCC: 1,0,0") {
		t.Fatalf("unexpected atcmd response: %q", out)
	}
	if data, err := os.ReadFile(calls); err != nil || strings.TrimSpace(string(data)) != "AT+CLCC" {
		t.Fatalf("fake AT call log = %q, err=%v", data, err)
	}
}

func TestBridgeATQuarantinesAfterACommandTimeout(t *testing.T) {
	lockPath := filepath.Join(t.TempDir(), "qmanager_at.lock")
	if err := os.WriteFile(lockPath, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	t.Setenv("X16_AT_LOCK", lockPath)
	script, calls := writeFakeAT(t, "exec sleep 2")
	b := &bridge{atBin: script}

	_, err := b.at("AT+CLCC", 100*time.Millisecond)
	if err == nil {
		t.Fatal("expected the fake modem command to time out")
	}
	if poisoned := b.atPoisoned.Load(); poisoned != "AT+CLCC" {
		t.Fatalf("timeout quarantine=%v, want AT+CLCC", poisoned)
	}

	// Polling is what must stop: another CLCC would pile a second request behind
	// the one that never came back.
	_, err = b.at("AT+CLCC", time.Second)
	if err == nil || !strings.Contains(err.Error(), "quarantined") {
		t.Fatalf("polling was not refused after a broker timeout: %v", err)
	}
	data, readErr := os.ReadFile(calls)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if got := strings.TrimSpace(string(data)); got != "AT+CLCC" {
		t.Fatalf("a polling request was sent after quarantine; command log=%q", got)
	}
}

// The safety valve: an operator whose call will not end must still be able to end
// it. A quarantined bridge sends CHUP anyway, and the reply proves the broker is
// alive again, which lifts the quarantine.
func TestHangupReachesModemWhileQuarantined(t *testing.T) {
	lockPath := filepath.Join(t.TempDir(), "qmanager_at.lock")
	if err := os.WriteFile(lockPath, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	t.Setenv("X16_AT_LOCK", lockPath)

	dir := t.TempDir()
	calls := filepath.Join(dir, "calls.log")
	script := filepath.Join(dir, "fake-atcmd")
	// The first command hangs (poisoning the path); every later command answers.
	body := "#!/bin/sh\n" +
		"echo \"$1\" >> \"" + calls + "\"\n" +
		"if [ \"$1\" = \"AT+CLCC\" ] && [ ! -f \"" + dir + "/poisoned\" ]; then\n" +
		"  : > \"" + dir + "/poisoned\"\n" +
		"  sleep 2\n" +
		"fi\n" +
		"printf 'atcmd_receive:\\nOK\\n'\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	b := &bridge{atBin: script}

	if _, err := b.at("AT+CLCC", 100*time.Millisecond); err == nil {
		t.Fatal("expected the first command to time out")
	}
	if b.atQuarantine() == "" {
		t.Fatal("expected the AT path to be quarantined after the timeout")
	}

	out, err := b.at("AT+CHUP", 2*time.Second)
	if err != nil {
		t.Fatalf("AT+CHUP must reach the modem while quarantined: %v", err)
	}
	if !strings.Contains(out, "OK") {
		t.Fatalf("AT+CHUP response = %q, want OK", out)
	}
	if q := b.atQuarantine(); q != "" {
		t.Fatalf("a reply should lift the quarantine, still poisoned by %q", q)
	}

	data, err := os.ReadFile(calls)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "AT+CHUP") {
		t.Fatalf("AT+CHUP never reached the modem; command log=%q", data)
	}
}

// CPAS is the fallback when CLCC wedges — which it does on this firmware while
// other commands still answer. A wrong mapping here would show a call that is not
// happening (or hide one that is), so each mode is pinned.
func TestCPASFallbackKeepsCallStateHonest(t *testing.T) {
	cases := []struct {
		mode   string
		have   bool
		stat   string
		reason string
	}{
		{"0", false, "", "ready means no call"},
		{"1", false, "", "not-available is not a call"},
		{"3", true, "3", "ringing is a call"},
		{"4", true, "0", "in-call maps to the active code the tap logic uses"},
		{"5", true, "0", "asleep-in-call is still a call"},
	}
	for _, tc := range cases {
		lockPath := filepath.Join(t.TempDir(), "qmanager_at.lock")
		if err := os.WriteFile(lockPath, nil, 0o666); err != nil {
			t.Fatal(err)
		}
		t.Setenv("X16_AT_LOCK", lockPath)
		script, _ := writeFakeAT(t, "printf 'atcmd_receive:\\n+CPAS: "+tc.mode+"\\n\\nOK\\n'")
		b := &bridge{atBin: script}
		snap, err := b.modemCallFromCPAS(false)
		if err != nil {
			t.Fatalf("mode %s: %v", tc.mode, err)
		}
		if snap.have != tc.have || snap.stat != tc.stat {
			t.Fatalf("mode %s -> have=%v stat=%q, want have=%v stat=%q (%s)",
				tc.mode, snap.have, snap.stat, tc.have, tc.stat, tc.reason)
		}
	}
}

// An answer with no mode line is "no information", never a fabricated idle.
func TestCPASWithoutAModeIsAnError(t *testing.T) {
	lockPath := filepath.Join(t.TempDir(), "qmanager_at.lock")
	if err := os.WriteFile(lockPath, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	t.Setenv("X16_AT_LOCK", lockPath)
	script, _ := writeFakeAT(t, "printf 'atcmd_receive:\\nOK\\n'")
	b := &bridge{atBin: script}
	if _, err := b.modemCallFromCPAS(false); err == nil {
		t.Fatal("a bare OK from AT+CPAS must not be read as a state")
	}
}
