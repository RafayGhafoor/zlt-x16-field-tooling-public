// certgen.go — self-provisioning TLS material.
//
// The page must be served over HTTPS (getUserMedia only exists in a secure
// context), so the module needs a certificate on every device it lands on. It is
// generated here rather than by openssl on purpose:
//
//   - the device ships openssl 1.1.1, whose `req -x509` applies its own v3_ca
//     section (basicConstraints CA:TRUE) in addition to any requested extensions,
//     which produces a duplicate extension and a certificate both Go and macOS
//     reject;
//   - a CA:TRUE certificate with no extendedKeyUsage is refused by the platform
//     verifiers in Safari/Chrome and reported as "not standards compliant";
//   - ECDSA P-256 is faster than RSA-2048 to generate and to hand-shake on this
//     1-core ARMv7, and is universally supported by browsers.
//
// The result is a correct chain: a local root CA (ca.go) and a leaf it signs,
// with CA:FALSE, digitalSignature, extendedKeyUsage=serverAuth, and SANs for the
// LAN IP, loopback and localhost. Publishing the root at /ca.crt is what lets a
// phone or laptop trust this device for good instead of once per certificate.

package main

import (
	"bytes"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"time"
)

// certUsable reports whether the file pair loads and is a serverAuth leaf for
// one of the wanted IPs. Anything else is replaced.
func certUsable(certPath, keyPath string, ips []string) bool {
	certPEM, err := os.ReadFile(certPath)
	if err != nil {
		return false
	}
	keyPEM, err := os.ReadFile(keyPath)
	if err != nil {
		return false
	}
	cb, _ := pem.Decode(certPEM)
	if cb == nil {
		return false
	}
	cert, err := x509.ParseCertificate(cb.Bytes)
	if err != nil {
		return false
	}
	if cert.IsCA {
		return false
	}
	var serverAuth bool
	for _, u := range cert.ExtKeyUsage {
		if u == x509.ExtKeyUsageServerAuth {
			serverAuth = true
		}
	}
	if !serverAuth {
		return false
	}
	kb, _ := pem.Decode(keyPEM)
	if kb == nil {
		return false
	}
	if _, err := x509.ParseECPrivateKey(kb.Bytes); err != nil {
		if _, err2 := x509.ParsePKCS8PrivateKey(kb.Bytes); err2 != nil {
			return false
		}
	}
	for _, want := range ips {
		ip := net.ParseIP(want)
		if ip == nil {
			continue
		}
		found := false
		for _, have := range cert.IPAddresses {
			if have.Equal(ip) {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return time.Now().Before(cert.NotAfter.Add(-24 * time.Hour))
}

// externalCert reports whether the leaf in place was NOT issued by our own CA —
// i.e. an operator provisioned it (Let's Encrypt via DNS-01, or a corporate PKI).
// Such a certificate is never overwritten implicitly: it is the one case where
// the local trust chain is deliberately bypassed.
func externalCert(certPath, keyPath, caCertPath string, ips []string) bool {
	if !certUsable(certPath, keyPath, ips) {
		return false
	}
	leaf, err := loadCert(certPath)
	if err != nil {
		return false
	}
	// A self-signed leaf is our own earlier provisioning (the version before the
	// local CA existed) — never an operator's, since no public CA issues one.
	// Replacing it is what upgrades the device from "warning every browser" to
	// "trusted once".
	if bytes.Equal(leaf.RawSubject, leaf.RawIssuer) {
		return false
	}
	ca, err := loadCert(caCertPath)
	if err != nil {
		return true // a CA-signed leaf and no CA on this device -> not ours: keep it
	}
	// Signature, not `Verify`: the clock may still be at 1970 during boot.
	return leaf.CheckSignatureFrom(ca) != nil
}

// ensureCert provisions TLS material. The shape it aims for is:
//
//	root CA on the device (ca.crt, published at /ca.crt for one-time install)
//	  └─ leaf signed by it (server.crt) — SANs for the LAN IP, loopback, localhost
//
// which is what removes the browser warning: once the root is trusted, every
// page served here is trusted, and the leaf can rotate for years without anyone
// touching their phone again.
func ensureCert(certPath, keyPath string, ips []string, force bool) (string, error) {
	caCertPath, caKeyPath := caPaths(certPath)

	if !force && externalCert(certPath, keyPath, caCertPath, ips) {
		return "kept externally provisioned certificate (not issued by the local CA)", nil
	}

	ca, caKey, created, err := ensureCA(caCertPath, caKeyPath)
	if err != nil {
		return "", fmt.Errorf("local CA: %w", err)
	}

	keepLeaf := !force && !created && leafGood(certPath, caCertPath, ips)
	if !keepLeaf {
		if err := issueLeaf(ca, caKey, certPath, keyPath, ips); err != nil {
			return "", fmt.Errorf("issue leaf: %w", err)
		}
	}

	what := "kept existing"
	if !keepLeaf {
		what = "issued"
	}
	root := "reused"
	if created {
		root = "created"
	}
	return fmt.Sprintf("%s leaf from local CA (%s root, SANs %v, valid %d days); CA SHA-256 %s",
		what, root, ips, leafValidityDays, caFingerprint(ca)), nil
}
