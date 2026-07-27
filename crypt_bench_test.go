package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"testing"
)

func BenchmarkGenerateChallenge(b *testing.B) {
	secret := SecretKey("0123456789abcdef0123456789abcdef")
	client := ClientContext{IP: "203.0.113.10", ConnID: "42"}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if _, err := GenerateChallenge(secret, 18, client); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkVerifySolution(b *testing.B) {
	secret := SecretKey("0123456789abcdef0123456789abcdef")
	client := ClientContext{IP: "203.0.113.10", ConnID: "42"}
	ch, err := GenerateChallenge(secret, 8, client)
	if err != nil {
		b.Fatal(err)
	}
	sol := benchSolve(b, ch, 8)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := VerifySolution(secret, sol, client); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkGenerateClearance(b *testing.B) {
	secret := SecretKey("0123456789abcdef0123456789abcdef")
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if _, err := GenerateClearance(secret, "203.0.113.10"); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkVerifyClearance(b *testing.B) {
	secret := SecretKey("0123456789abcdef0123456789abcdef")
	tok, err := GenerateClearance(secret, "203.0.113.10")
	if err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := VerifyClearance(secret, tok, "203.0.113.10"); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkGetCookie(b *testing.B) {
	header := "a=1; challenge=abcXYZ; challenge-sig=sigVAL; challenge-nonce=42; other=zz"
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = getCookie(header, "challenge")
		_ = getCookie(header, "challenge-sig")
		_ = getCookie(header, "challenge-nonce")
	}
}

func BenchmarkParseChallengeCookies(b *testing.B) {
	header := "a=1; challenge=abcXYZ; challenge-sig=sigVAL; challenge-nonce=42; challenge-clearance=body.sig; other=zz"
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = parseChallengeCookies(header)
	}
}

func BenchmarkVerifyClearanceMACReuse(b *testing.B) {
	secret := SecretKey("0123456789abcdef0123456789abcdef")
	mac := hmac.New(sha256.New, secret)
	var buf [32]byte
	tok, err := generateClearanceMAC(mac, buf[:0], "203.0.113.10")
	if err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := verifyClearanceMAC(mac, buf[:0], tok, "203.0.113.10"); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkHasLeadingZeroBits(b *testing.B) {
	sum := sha256.Sum256([]byte("bench"))
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = hasLeadingZeroBits(sum[:], 18)
	}
}

func BenchmarkSolveDifficulty8(b *testing.B) {
	secret := SecretKey("0123456789abcdef0123456789abcdef")
	client := ClientContext{IP: "1.2.3.4"}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		ch, err := GenerateChallenge(secret, 8, client)
		if err != nil {
			b.Fatal(err)
		}
		_ = benchSolve(b, ch, 8)
	}
}

func benchSolve(b *testing.B, ch SignedChallenge, diff uint) Solution {
	b.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(ch.Challenge)
	if err != nil {
		b.Fatal(err)
	}
	var nonce uint64
	for {
		nb := make([]byte, 8)
		binary.BigEndian.PutUint64(nb, nonce)
		data := make([]byte, len(raw)+8)
		copy(data, raw)
		copy(data[len(raw):], nb)
		sum := sha256.Sum256(data)
		if hasLeadingZeroBits(sum[:], diff) {
			return Solution{SignedChallenge: ch, Nonce: nonce}
		}
		nonce++
		if nonce > 1<<24 {
			b.Fatal("could not solve")
		}
	}
}
