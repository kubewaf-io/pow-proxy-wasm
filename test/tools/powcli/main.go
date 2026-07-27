// powcli — small helper for integration/perf tests.
//
// Commands:
//
//	powcli mint-clearance -secret S -ip IP
//	powcli solve -secret S -challenge C -signature SIG
//	powcli solve-cookies -secret S -cookie "challenge=...; challenge-sig=..."
package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

const (
	clearanceLifetime = 30 * time.Minute
	minSecretLen      = 32
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "mint-clearance":
		cmdMintClearance(os.Args[2:])
	case "solve":
		cmdSolve(os.Args[2:])
	case "solve-cookies":
		cmdSolveCookies(os.Args[2:])
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `usage:
  powcli mint-clearance -secret S -ip IP
  powcli solve -secret S -challenge C -signature SIG
  powcli solve-cookies -secret S -cookie "challenge=...; challenge-sig=..."

Outputs:
  mint-clearance  → clearance token on stdout
  solve*          → JSON {"c":"...","s":"...","n":123} and cookie header lines on stderr
`)
}

func cmdMintClearance(args []string) {
	fs := flag.NewFlagSet("mint-clearance", flag.ExitOnError)
	secret := fs.String("secret", "", "HMAC secret (≥32 bytes)")
	ip := fs.String("ip", "", "client IP to bind")
	_ = fs.Parse(args)
	mustSecret(*secret)
	tok, err := generateClearance([]byte(*secret), *ip)
	if err != nil {
		fail(err)
	}
	fmt.Println(tok)
}

func cmdSolve(args []string) {
	fs := flag.NewFlagSet("solve", flag.ExitOnError)
	secret := fs.String("secret", "", "HMAC secret (≥32 bytes)")
	challenge := fs.String("challenge", "", "base64url challenge (c)")
	signature := fs.String("signature", "", "base64url signature (s)")
	maxNonce := fs.Uint64("max-nonce", 1<<24, "abort after this many nonces")
	_ = fs.Parse(args)
	mustSecret(*secret)
	if *challenge == "" || *signature == "" {
		fail(errors.New("-challenge and -signature required"))
	}
	nonce, err := solvePoW(*challenge, *maxNonce)
	if err != nil {
		fail(err)
	}
	// Verify with secret so we fail early on bad signature material.
	if err := verifySolution([]byte(*secret), *challenge, *signature, nonce); err != nil {
		fail(fmt.Errorf("solved but verify failed: %w", err))
	}
	printSolution(*challenge, *signature, nonce)
}

func cmdSolveCookies(args []string) {
	fs := flag.NewFlagSet("solve-cookies", flag.ExitOnError)
	secret := fs.String("secret", "", "HMAC secret (≥32 bytes)")
	cookie := fs.String("cookie", "", "Cookie header value")
	maxNonce := fs.Uint64("max-nonce", 1<<24, "abort after this many nonces")
	_ = fs.Parse(args)
	mustSecret(*secret)
	if *cookie == "" {
		fail(errors.New("-cookie required"))
	}
	c := getCookie(*cookie, "challenge")
	s := getCookie(*cookie, "challenge-sig")
	if c == "" || s == "" {
		fail(errors.New("cookie must include challenge and challenge-sig"))
	}
	nonce, err := solvePoW(c, *maxNonce)
	if err != nil {
		fail(err)
	}
	if err := verifySolution([]byte(*secret), c, s, nonce); err != nil {
		fail(fmt.Errorf("solved but verify failed: %w", err))
	}
	printSolution(c, s, nonce)
}

func printSolution(challenge, signature string, nonce uint64) {
	out := map[string]any{"c": challenge, "s": signature, "n": nonce}
	enc, _ := json.Marshal(out)
	fmt.Println(string(enc))
	// Cookie lines for curl -b / integration scripts
	fmt.Fprintf(os.Stderr, "challenge=%s; challenge-sig=%s; challenge-nonce=%d\n",
		challenge, signature, nonce)
}

func mustSecret(s string) {
	if len(s) < minSecretLen {
		fail(fmt.Errorf("secret must be ≥%d bytes (got %d)", minSecretLen, len(s)))
	}
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "error: %v\n", err)
	os.Exit(1)
}

// --- crypto (mirrors crypt.go; standalone so tests need no package import) ---

type challengePayload struct {
	Timestamp  int64  `json:"ts"`
	Expiry     int64  `json:"exp"`
	Difficulty uint   `json:"diff"`
	Salt       string `json:"salt"`
	Context    string `json:"ctx,omitempty"`
	ConnID     string `json:"cid,omitempty"`
}

// Fixed-layout clearance (mirrors crypt.go option B):
// body = base64url(exp_be64 || salt16 || ip_utf8)
// token = body + "." + base64url(HMAC-SHA256(body))
func generateClearance(secret []byte, context string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	exp := time.Now().Add(clearanceLifetime).Unix()
	ipb := []byte(context)
	raw := make([]byte, 8+16+len(ipb))
	binary.BigEndian.PutUint64(raw[0:8], uint64(exp))
	copy(raw[8:24], salt)
	copy(raw[24:], ipb)
	body := base64.RawURLEncoding.EncodeToString(raw)
	h := hmac.New(sha256.New, secret)
	h.Write([]byte(body))
	sig := base64.RawURLEncoding.EncodeToString(h.Sum(nil))
	return body + "." + sig, nil
}

func solvePoW(challengeB64 string, maxNonce uint64) (uint64, error) {
	raw, err := base64.RawURLEncoding.DecodeString(challengeB64)
	if err != nil {
		return 0, fmt.Errorf("decode challenge: %w", err)
	}
	var payload challengePayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return 0, fmt.Errorf("parse challenge: %w", err)
	}
	diff := payload.Difficulty
	var nonce uint64
	nb := make([]byte, 8)
	data := make([]byte, len(raw)+8)
	copy(data, raw)
	for {
		binary.BigEndian.PutUint64(nb, nonce)
		copy(data[len(raw):], nb)
		sum := sha256.Sum256(data)
		if hasLeadingZeroBits(sum[:], diff) {
			return nonce, nil
		}
		nonce++
		if nonce > maxNonce {
			return 0, fmt.Errorf("could not solve difficulty=%d within %d nonces", diff, maxNonce)
		}
	}
}

func verifySolution(secret []byte, challenge, signature string, nonce uint64) error {
	chBytes, err := base64.RawURLEncoding.DecodeString(challenge)
	if err != nil {
		return err
	}
	var payload challengePayload
	if err := json.Unmarshal(chBytes, &payload); err != nil {
		return err
	}
	if time.Now().Unix() > payload.Expiry {
		return errors.New("challenge expired")
	}
	h := hmac.New(sha256.New, secret)
	h.Write([]byte(challenge))
	expectedSig := h.Sum(nil)
	sigBytes, err := base64.RawURLEncoding.DecodeString(signature)
	if err != nil {
		return err
	}
	if subtle.ConstantTimeCompare(expectedSig, sigBytes) != 1 {
		return errors.New("bad signature")
	}
	nb := make([]byte, 8)
	binary.BigEndian.PutUint64(nb, nonce)
	data := make([]byte, len(chBytes)+8)
	copy(data, chBytes)
	copy(data[len(chBytes):], nb)
	sum := sha256.Sum256(data)
	if !hasLeadingZeroBits(sum[:], payload.Difficulty) {
		return errors.New("bad pow")
	}
	return nil
}

func hasLeadingZeroBits(hash []byte, bits uint) bool {
	if bits == 0 {
		return true
	}
	for i := uint(0); i < bits; i++ {
		byteIdx := i / 8
		if byteIdx >= uint(len(hash)) {
			return false
		}
		bitIdx := 7 - (i % 8)
		if (hash[byteIdx] & (1 << bitIdx)) != 0 {
			return false
		}
	}
	return true
}

func getCookie(cookieHeader, name string) string {
	if cookieHeader == "" {
		return ""
	}
	prefix := name + "="
	if strings.HasPrefix(cookieHeader, prefix) {
		rest := cookieHeader[len(prefix):]
		if idx := strings.IndexByte(rest, ';'); idx >= 0 {
			return strings.TrimSpace(rest[:idx])
		}
		return strings.TrimSpace(rest)
	}
	for _, search := range []string{"; " + prefix, ";" + prefix} {
		if idx := strings.Index(cookieHeader, search); idx != -1 {
			start := idx + len(search)
			if end := strings.IndexByte(cookieHeader[start:], ';'); end != -1 {
				return strings.TrimSpace(cookieHeader[start : start+end])
			}
			return strings.TrimSpace(cookieHeader[start:])
		}
	}
	return ""
}
