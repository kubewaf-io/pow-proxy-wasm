package main

import "testing"

func TestGetCookie(t *testing.T) {
	cases := []struct {
		header string
		name   string
		want   string
	}{
		{"", "challenge", ""},
		{"challenge=abc", "challenge", "abc"},
		{"challenge=abc; challenge-sig=xyz", "challenge", "abc"},
		{"challenge=abc; challenge-sig=xyz", "challenge-sig", "xyz"},
		{"foo=1; challenge=val; bar=2", "challenge", "val"},
		{"challenge=abc;challenge-sig=xyz", "challenge-sig", "xyz"},
		{"other=1", "challenge", ""},
		{"challenge=  spaced  ", "challenge", "spaced"},
		{"a=1; challenge-nonce=42; b=2", "challenge-nonce", "42"},
	}
	for _, tc := range cases {
		if got := getCookie(tc.header, tc.name); got != tc.want {
			t.Errorf("getCookie(%q, %q)=%q want %q", tc.header, tc.name, got, tc.want)
		}
	}
}

func TestParseChallengeCookies(t *testing.T) {
	h := "a=1; challenge=abc; challenge-sig=sig; challenge-nonce=9; challenge-clearance=cltok; b=2"
	got := parseChallengeCookies(h)
	if got.challenge != "abc" || got.signature != "sig" || got.nonce != "9" || got.clearance != "cltok" {
		t.Fatalf("got %+v", got)
	}
	// single-pass equals individual getCookie
	if got.challenge != getCookie(h, "challenge") {
		t.Fatal("challenge mismatch")
	}
	empty := parseChallengeCookies("")
	if empty.clearance != "" || empty.challenge != "" {
		t.Fatal("expected empty")
	}
	// IPv6-looking values without separators in name still work
	h2 := "challenge-clearance=body.sig"
	if parseChallengeCookies(h2).clearance != "body.sig" {
		t.Fatal("clearance with dot in value")
	}
}

func TestSetCookie(t *testing.T) {
	got := setCookie("challenge", "tok", 60, false, false)
	if got != "challenge=tok; Path=/; Max-Age=60; SameSite=Lax" {
		t.Fatalf("got %q", got)
	}
	got = setCookie("challenge-clearance", "tok", 1800, true, true)
	if got != "challenge-clearance=tok; Path=/; Max-Age=1800; SameSite=Lax; HttpOnly; Secure" {
		t.Fatalf("got %q", got)
	}
}

func TestClearCookie(t *testing.T) {
	got := clearCookie("challenge", false)
	if got != "challenge=; Path=/; Max-Age=0; SameSite=Lax" {
		t.Fatalf("got %q", got)
	}
	got = clearCookie("challenge-clearance", true)
	if got != "challenge-clearance=; Path=/; Max-Age=0; SameSite=Lax; Secure; HttpOnly" {
		t.Fatalf("got %q", got)
	}
}

func TestClampDifficulty(t *testing.T) {
	if got := clampDifficulty(5, 12, 26); got != 12 {
		t.Fatalf("below min: %d", got)
	}
	if got := clampDifficulty(30, 12, 26); got != 26 {
		t.Fatalf("above max: %d", got)
	}
	if got := clampDifficulty(18, 12, 26); got != 18 {
		t.Fatalf("in range: %d", got)
	}
}

func TestGetEffectiveDifficulty(t *testing.T) {
	p := &pluginContext{
		baseDifficulty: 18,
		minDifficulty:  12,
		maxDifficulty:  26,
		currentDiff:    20,
	}
	d, src := p.getEffectiveDifficulty("")
	if d != 20 || src != diffSourceDynamic {
		t.Fatalf("dynamic: d=%d src=%s", d, src)
	}
	d, src = p.getEffectiveDifficulty("22")
	if d != 22 || src != diffSourceHeader {
		t.Fatalf("header: d=%d src=%s", d, src)
	}
	d, src = p.getEffectiveDifficulty("99")
	if d != 26 || src != diffSourceHeader {
		t.Fatalf("header clamp: d=%d src=%s", d, src)
	}
	// currentDiff=0 falls through to GetSharedData (host ABI); without a Wasm host
	// that panics. Cover the header path + local dynamic path only here.
	p.currentDiff = 15
	d, src = p.getEffectiveDifficulty("")
	if d != 15 || src != diffSourceDynamic {
		t.Fatalf("local dynamic: d=%d src=%s", d, src)
	}
}

func TestHasLeadingZeroBits(t *testing.T) {
	// All-zero hash satisfies any reasonable difficulty.
	zero := make([]byte, 32)
	if !hasLeadingZeroBits(zero, 0) {
		t.Fatal("0 bits should pass")
	}
	if !hasLeadingZeroBits(zero, 16) {
		t.Fatal("zero hash should pass 16 bits")
	}
	// 0x0f = 00001111 → first 4 bits are zero
	h := make([]byte, 32)
	h[0] = 0x0f
	if !hasLeadingZeroBits(h, 4) {
		t.Fatal("expected 4 leading zero bits")
	}
	if hasLeadingZeroBits(h, 5) {
		t.Fatal("should fail 5 leading zero bits")
	}
}
