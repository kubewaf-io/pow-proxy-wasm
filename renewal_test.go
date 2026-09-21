package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"hash"
	"testing"
	"time"
)

func TestParseSlidingRenewalConfig(t *testing.T) {
	cases := []struct {
		name   string
		config string
		window int64
		ttl    int64
	}{
		{"off by default", `{}`, 0, 0},
		{"explicit window enables", `{"sliding_renewal_ttl":30}`, 30, 30 * RenewalTTLMultiple},
		{"explicit both", `{"sliding_renewal_ttl":30,"renewal_ttl":600}`, 30, 600},
		{"explicit zero stays off", `{"sliding_renewal_ttl":0}`, 0, 0},
		{"negative stays off", `{"sliding_renewal_ttl":-5}`, 0, 0},
		{"zero renewal falls back", `{"sliding_renewal_ttl":5,"renewal_ttl":0}`, 5, 5 * RenewalTTLMultiple},
		{"renewal without window stays off", `{"renewal_ttl":600}`, 0, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			window, ttl := parseSlidingRenewalConfig([]byte(tc.config))
			if window != tc.window || ttl != tc.ttl {
				t.Fatalf("got window=%d ttl=%d, want %d/%d", window, ttl, tc.window, tc.ttl)
			}
		})
	}
}

func TestShouldRenewClearance(t *testing.T) {
	const exp = int64(1000)
	cases := []struct {
		name      string
		now       int64
		window    int64
		wantRenew bool
	}{
		{"not yet expired", 999, 10, false},
		{"still valid", 1000, 10, false},
		{"just expired in window", 1001, 10, true},
		{"at window edge", 1010, 10, true},
		{"beyond window", 1011, 10, false},
		{"far beyond window", 2000, 10, false},
		{"window disabled", 1005, 0, false},
		{"negative window", 1005, -1, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := shouldRenewClearance(exp, tc.now, tc.window); got != tc.wantRenew {
				t.Fatalf("shouldRenewClearance(exp=%d, now=%d, window=%d) = %v, want %v",
					exp, tc.now, tc.window, got, tc.wantRenew)
			}
		})
	}
}

// clearanceWithExpiry builds a correctly signed clearance token with an
// arbitrary expiry (GenerateClearance always uses now+ClearanceLifetime).
func clearanceWithExpiry(mac hash.Hash, sumBuf []byte, exp int64, ip string) string {
	body := encodeClearanceBody(exp, []byte("0123456789abcdef"), ip)
	mac.Reset()
	mac.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(sumBuf))
}

func TestSlidingRenewalExpiredToken(t *testing.T) {
	secret := SecretKey("0123456789abcdef0123456789abcdef")
	mac := hmac.New(sha256.New, secret)
	var buf [32]byte

	// Clearance that expired 5s ago, signed and IP-bound to 10.0.0.1.
	exp := time.Now().Unix() - 5
	tok := clearanceWithExpiry(mac, buf[:0], exp, "10.0.0.1")

	// parseClearanceMAC exposes the expiry without expiry policy.
	gotExp, err := parseClearanceMAC(mac, buf[:0], tok, "10.0.0.1")
	if err != nil || gotExp != exp {
		t.Fatalf("parseClearanceMAC = (%d, %v), want (%d, nil)", gotExp, err, exp)
	}
	// Old verify still reports expiry for the same token.
	if err := verifyClearanceMAC(mac, buf[:0], tok, "10.0.0.1"); err != ErrExpired {
		t.Fatalf("verifyClearanceMAC = %v, want ErrExpired", err)
	}
	// Renewal eligibility follows the window.
	now := time.Now().Unix()
	if !shouldRenewClearance(exp, now, 10) {
		t.Fatal("expired 5s ago should be renewable with a 10s window")
	}
	if shouldRenewClearance(exp, now, 3) {
		t.Fatal("expired 5s ago must not be renewable with a 3s window")
	}
	// IP binding is enforced before renewal: a different client IP is rejected.
	if _, err := parseClearanceMAC(mac, buf[:0], tok, "10.0.0.2"); err != ErrContextMismatch {
		t.Fatalf("wrong IP = %v, want ErrContextMismatch", err)
	}
	// Tampered token is rejected outright.
	if _, err := parseClearanceMAC(mac, buf[:0], tok[:len(tok)-1]+"A", "10.0.0.1"); err != ErrBadSignature {
		t.Fatalf("tampered token = %v, want ErrBadSignature", err)
	}
}

func TestParseClearanceMACToken(t *testing.T) {
	secret := SecretKey("0123456789abcdef0123456789abcdef")
	mac := hmac.New(sha256.New, secret)
	var buf [32]byte

	tok, err := generateClearanceMAC(mac, buf[:0], "10.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	gotExp, err := parseClearanceMAC(mac, buf[:0], tok, "10.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	// Fresh clearance: expiry in the future, parse agrees with verify.
	if gotExp <= time.Now().Unix() {
		t.Fatalf("fresh clearance exp %d not in the future", gotExp)
	}
}
