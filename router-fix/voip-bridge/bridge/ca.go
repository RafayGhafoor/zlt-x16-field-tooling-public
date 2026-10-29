// ca.go — a local certificate authority for the device, so browsers trust it.
//
// Why a local CA and not Let's Encrypt: this host is 192.168.3.1, a private
// address. ACME cannot validate it — HTTP-01 requires the public internet to
// reach the device (it cannot), and DNS-01 requires control of a public zone,
// which a private address does not give you (sslip.io/nip.io hand out a
// *hostname* for an IP, but the zone belongs to them, so no challenge record can
// be written). A public CA becomes reachable only if the customer owns a domain
// and publishes a DNS-01 record pointing a name at 192.168.3.1 — that path is
// still supported here: drop an externally issued cert+key in place (and clear
// ca.key) and the bridge uses them as-is.
//
// What this file provides instead is the shape every LAN device uses (pfSense,
// Home Assistant, Synology): one long-lived root kept on the device, and a short
// leaf issued from it. The root is published at /ca.crt for a one-time install
// on a phone or laptop; after that every page here is trusted with no warnings,
// and the leaf can be rotated without touching any client.
//
// Hierarchy:
//
//	ca.crt / ca.key   ECDSA P-256, CA:TRUE, pathlen:0, 10 years   (the root)
//	server.crt/.key   ECDSA P-256, CA:FALSE, serverAuth, SAN IP   (825 days)
//
// 825 days is Apple's limit for a publicly trusted leaf, so staying under it
// means the same certificate is accepted by Safari/iOS as well.

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	caValidityDays   = 3650
	leafValidityDays = 825
)

// caPaths derives the CA files next to the leaf.
func caPaths(certPath string) (caCert, caKey string) {
	dir := filepath.Dir(certPath)
	return filepath.Join(dir, "ca.crt"), filepath.Join(dir, "ca.key")
}

func loadCert(path string) (*x509.Certificate, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil, fmt.Errorf("%s: not a PEM file", path)
	}
	return x509.ParseCertificate(blk.Bytes)
}

func loadECKey(path string) (*ecdsa.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil, fmt.Errorf("%s: not a PEM file", path)
	}
	key, err := x509.ParseECPrivateKey(blk.Bytes)
	if err != nil {
		if k, err2 := x509.ParsePKCS8PrivateKey(blk.Bytes); err2 == nil {
			if ec, ok := k.(*ecdsa.PrivateKey); ok {
				return ec, nil
			}
		}
		return nil, err
	}
	return key, nil
}

func writePEM(path, blockType string, der []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if err := pem.Encode(f, &pem.Block{Type: blockType, Bytes: der}); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func randomSerial() (*big.Int, error) {
	max := new(big.Int).Lsh(big.NewInt(1), 128)
	return rand.Int(rand.Reader, max)
}

// ensureCA creates the root if it is missing and returns it with its key.
// `created` says whether this call minted a new root (which invalidates every
// previously installed trust decision).
func ensureCA(caCertPath, caKeyPath string) (cert *x509.Certificate, key *ecdsa.PrivateKey, created bool, err error) {
	if c, e := loadCert(caCertPath); e == nil {
		if k, e2 := loadECKey(caKeyPath); e2 == nil && c.IsCA && time.Now().Before(c.NotAfter) {
			return c, k, false, nil
		}
	}

	key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, false, err
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, nil, false, err
	}
	pub, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		return nil, nil, false, err
	}
	skid := sha1.Sum(pub)

	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "ZLT X16 local CA",
			Organization: []string{"ZLT X16 call terminal"},
		},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().AddDate(0, 0, caValidityDays),
		IsCA:                  true,
		BasicConstraintsValid: true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		SubjectKeyId:          skid[:],
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, false, err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, nil, false, err
	}
	if err := os.MkdirAll(filepath.Dir(caCertPath), 0o755); err != nil {
		return nil, nil, false, err
	}
	if err := writePEM(caCertPath, "CERTIFICATE", der, 0o644); err != nil {
		return nil, nil, false, err
	}
	if err := writePEM(caKeyPath, "EC PRIVATE KEY", keyDER, 0o600); err != nil {
		return nil, nil, false, err
	}
	c, perr := x509.ParseCertificate(der)
	return c, key, true, perr
}

// issueLeaf signs a server certificate for `ips` with the local CA.
func issueLeaf(ca *x509.Certificate, caKey *ecdsa.PrivateKey, certPath, keyPath string, ips []string) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := randomSerial()
	if err != nil {
		return err
	}
	pub, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		return err
	}
	skid := sha1.Sum(pub)

	var ipAddrs []net.IP
	for _, s := range ips {
		if ip := net.ParseIP(s); ip != nil {
			ipAddrs = append(ipAddrs, ip)
		}
	}
	ipAddrs = append(ipAddrs, net.IPv4(127, 0, 0, 1))

	cn := "zlt-x16"
	if len(ipAddrs) > 0 {
		cn = ipAddrs[0].String()
	}

	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   cn,
			Organization: []string{"ZLT X16 call terminal"},
		},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().AddDate(0, 0, leafValidityDays),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  false,
		IPAddresses:           ipAddrs,
		DNSNames:              []string{"localhost"},
		SubjectKeyId:          skid[:],
		AuthorityKeyId:        ca.SubjectKeyId,
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, &key.PublicKey, caKey)
	if err != nil {
		return err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	if err := writePEM(certPath, "CERTIFICATE", der, 0o644); err != nil {
		return err
	}
	return writePEM(keyPath, "EC PRIVATE KEY", keyDER, 0o600)
}

// caFingerprint is what a user compares against the file they are about to
// trust: colon-separated uppercase hex, the form every OS shows.
func caFingerprint(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.Raw)
	out := make([]byte, 0, len(sum)*3)
	for i, b := range sum {
		if i > 0 {
			out = append(out, ':')
		}
		out = append(out, []byte(hex.EncodeToString([]byte{b}))...)
	}
	for i := range out {
		if out[i] >= 'a' && out[i] <= 'f' {
			out[i] -= 'a' - 'A'
		}
	}
	return string(out)
}

// leafGood reports whether the current leaf was issued by our CA and still
// covers the wanted IPs with enough validity left — i.e. whether it can be kept.
//
// Signatures decide ownership, not validity windows: this device boots with an
// unsynced clock (1970 until NTP lands), and `x509.Verify` at that instant
// rejects every certificate as "not yet valid". Using CheckSignatureFrom keeps a
// boot from re-issuing a fresh leaf (and printing a misleading reason) before the
// clock has caught up.
func leafGood(certPath, caCertPath string, ips []string) bool {
	leaf, err := loadCert(certPath)
	if err != nil {
		return false
	}
	ca, err := loadCert(caCertPath)
	if err != nil {
		return false
	}
	if err := leaf.CheckSignatureFrom(ca); err != nil {
		return false
	}
	for _, want := range ips {
		ip := net.ParseIP(want)
		if ip == nil {
			continue
		}
		found := false
		for _, have := range leaf.IPAddresses {
			if have.Equal(ip) {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	now := time.Now()
	if now.Year() < 2024 {
		// Clock not synced yet — do not rotate certificates on a wrong clock.
		return true
	}
	// Re-issue a month early so no client ever meets an expired leaf.
	return now.After(leaf.NotBefore) && now.Before(leaf.NotAfter.Add(-30*24*time.Hour))
}
