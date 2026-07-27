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
	"hash"
	"strings"
	"time"
)

const (
	// DefaultDifficulty is used when no difficulty is configured.
	DefaultDifficulty = 18

	// ChallengeLifetime is how long a PoW challenge remains valid to solve.
	// Cookie Max-Age for challenge/challenge-sig/challenge-nonce must match this.
	ChallengeLifetime = 60 * time.Second

	// ClearanceLifetime is how long a successful solve grants access without re-solving.
	// Implemented as a separate signed clearance cookie (HttpOnly).
	ClearanceLifetime = 30 * time.Minute

	// MinSecretLen is the minimum accepted HMAC secret length.
	MinSecretLen = 32

	// clearanceSaltLen is the random salt size embedded in fixed-layout clearance tokens.
	clearanceSaltLen = 16
	// clearanceFixedPrefix is exp (8) + salt (16).
	clearanceFixedPrefix = 8 + clearanceSaltLen
)

// SecretKey should be 32+ random bytes, loaded from env/config once at startup.
type SecretKey []byte

// ClientContext is the request identity used for token binding.
//
// Challenge tokens bind IP + Envoy connection.id (same downstream connection).
// Clearance tokens bind IP only so they survive reloads / new connections after a solve.
type ClientContext struct {
	// IP is the normalized client address (may be empty if unknown).
	IP string
	// ConnID is Envoy's downstream connection.id (stable for one TCP/TLS connection).
	// Empty when the property is unavailable (e.g. unit tests, some runtimes).
	ConnID string
}

// ClearanceBind returns the long-lived clearance context (IP only).
func (c ClientContext) ClearanceBind() string {
	return c.IP
}

// String is a compact log form.
func (c ClientContext) String() string {
	if c.IP == "" && c.ConnID == "" {
		return ""
	}
	if c.ConnID == "" {
		return c.IP
	}
	if c.IP == "" {
		return "cid=" + c.ConnID
	}
	return c.IP + ";cid=" + c.ConnID
}

type ChallengePayload struct {
	Timestamp  int64  `json:"ts"`            // unix seconds
	Expiry     int64  `json:"exp"`           // unix seconds
	Difficulty uint   `json:"diff"`          // leading zero bits
	Salt       string `json:"salt"`          // base64url random bytes
	Context    string `json:"ctx,omitempty"` // client IP
	// ConnID is Envoy downstream connection.id at challenge issue time.
	// Verified strictly when both issue and verify see a non-empty id.
	ConnID string `json:"cid,omitempty"`
}

type SignedChallenge struct {
	Challenge string `json:"c"` // base64url(JSON payload)
	Signature string `json:"s"` // base64url(HMAC-SHA256)
}

type Solution struct {
	SignedChallenge
	Nonce uint64 `json:"n"`
}

// GenerateChallenge returns a signed challenge ready to send to the client.
// client binds IP and, when available, Envoy connection.id.
func GenerateChallenge(secret SecretKey, difficulty uint, client ClientContext) (SignedChallenge, error) {
	return generateChallengeMAC(hmac.New(sha256.New, secret), nil, difficulty, client)
}

// generateChallengeMAC is the hot-path variant that reuses a plugin-owned HMAC digester.
// sumBuf should be macSumBuf[:0] or nil (allocates on Sum when nil).
func generateChallengeMAC(mac hash.Hash, sumBuf []byte, difficulty uint, client ClientContext) (SignedChallenge, error) {
	if difficulty < 1 {
		difficulty = DefaultDifficulty
	}

	now := time.Now()
	payload := ChallengePayload{
		Timestamp:  now.Unix(),
		Expiry:     now.Add(ChallengeLifetime).Unix(),
		Difficulty: difficulty,
		Context:    client.IP,
		ConnID:     client.ConnID,
	}

	salt, err := randomBytes(32)
	if err != nil {
		return SignedChallenge{}, err
	}
	payload.Salt = base64.RawURLEncoding.EncodeToString(salt)

	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return SignedChallenge{}, err
	}

	challenge := base64.RawURLEncoding.EncodeToString(payloadBytes)

	// Sign the challenge token (not the raw JSON) → easy for any client language
	mac.Reset()
	mac.Write([]byte(challenge))
	sig := mac.Sum(sumBuf)

	return SignedChallenge{
		Challenge: challenge,
		Signature: base64.RawURLEncoding.EncodeToString(sig),
	}, nil
}

// GenerateClearance returns a signed clearance token cookie value (fixed layout, option B):
//
//	body = base64url(exp_be64 || salt16 || ip_utf8)
//	token = body + "." + base64url(HMAC-SHA256(body))
//
// No JSON on the hot path. IP may be empty. IPv6 is fine (binary payload, not colon-split).
func GenerateClearance(secret SecretKey, context string) (string, error) {
	return generateClearanceMAC(hmac.New(sha256.New, secret), nil, context)
}

func generateClearanceMAC(mac hash.Hash, sumBuf []byte, context string) (string, error) {
	salt, err := randomBytes(clearanceSaltLen)
	if err != nil {
		return "", err
	}
	exp := time.Now().Add(ClearanceLifetime).Unix()
	body := encodeClearanceBody(exp, salt, context)
	mac.Reset()
	mac.Write([]byte(body))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(sumBuf))
	return body + "." + sig, nil
}

// encodeClearanceBody packs exp||salt||ip and base64url-encodes it (no '.' in output).
func encodeClearanceBody(exp int64, salt []byte, ip string) string {
	ipb := []byte(ip)
	raw := make([]byte, clearanceFixedPrefix+len(ipb))
	binary.BigEndian.PutUint64(raw[0:8], uint64(exp))
	copy(raw[8:8+clearanceSaltLen], salt)
	copy(raw[clearanceFixedPrefix:], ipb)
	return base64.RawURLEncoding.EncodeToString(raw)
}

// decodeClearanceBody reverses encodeClearanceBody.
func decodeClearanceBody(body string) (exp int64, ip string, err error) {
	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil || len(raw) < clearanceFixedPrefix {
		return 0, "", ErrInvalidToken
	}
	exp = int64(binary.BigEndian.Uint64(raw[0:8]))
	// salt is raw[8:24]; not needed after verify
	ip = string(raw[clearanceFixedPrefix:])
	return exp, ip, nil
}

// randomBytes returns cryptographically secure random bytes.
func randomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	_, err := rand.Read(b)
	return b, err
}

var (
	ErrInvalidToken    = errors.New("invalid token format")
	ErrExpired         = errors.New("challenge expired")
	ErrBadSignature    = errors.New("bad signature")
	ErrBadPoW          = errors.New("invalid proof of work")
	ErrContextMismatch = errors.New("context mismatch")
)

// hasLeadingZeroBits reports whether the hash has at least `bits` leading zero bits.
// Matches the JS implementation in challenge.html.
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

// VerifySolution validates a client-submitted Solution sent via cookies or challenge-token header.
func VerifySolution(secret SecretKey, sol Solution, expected ClientContext) error {
	return verifySolutionMAC(hmac.New(sha256.New, secret), nil, sol, expected)
}

func verifySolutionMAC(mac hash.Hash, sumBuf []byte, sol Solution, expected ClientContext) error {
	if sol.Challenge == "" || sol.Signature == "" {
		return ErrInvalidToken
	}

	chBytes, err := base64.RawURLEncoding.DecodeString(sol.Challenge)
	if err != nil {
		return ErrInvalidToken
	}

	var payload ChallengePayload
	if err := json.Unmarshal(chBytes, &payload); err != nil {
		return ErrInvalidToken
	}

	if time.Now().Unix() > payload.Expiry {
		return ErrExpired
	}

	mac.Reset()
	mac.Write([]byte(sol.Challenge))
	expectedSig := mac.Sum(sumBuf)

	sigBytes, err := base64.RawURLEncoding.DecodeString(sol.Signature)
	if err != nil {
		return ErrBadSignature
	}
	if subtle.ConstantTimeCompare(expectedSig, sigBytes) != 1 {
		return ErrBadSignature
	}

	nonceBytes := make([]byte, 8)
	binary.BigEndian.PutUint64(nonceBytes, sol.Nonce)

	data := make([]byte, len(chBytes)+8)
	copy(data, chBytes)
	copy(data[len(chBytes):], nonceBytes)

	sum := sha256.Sum256(data)
	if !hasLeadingZeroBits(sum[:], payload.Difficulty) {
		return ErrBadPoW
	}

	if err := matchChallengeContext(payload.Context, payload.ConnID, expected); err != nil {
		return err
	}

	return nil
}

// matchChallengeContext enforces IP and connection.id binding for a PoW solution.
func matchChallengeContext(tokenIP, tokenCID string, expected ClientContext) error {
	if expected.IP != "" {
		if tokenIP == "" || tokenIP != expected.IP {
			return ErrContextMismatch
		}
	}
	if tokenCID != "" && expected.ConnID != "" && tokenCID != expected.ConnID {
		return ErrContextMismatch
	}
	return nil
}

// VerifyClearance validates a challenge-clearance cookie (fixed-layout option B).
// expectedIP is the current client IP (clearance is not bound to connection.id).
func VerifyClearance(secret SecretKey, token string, expectedIP string) error {
	return verifyClearanceMAC(hmac.New(sha256.New, secret), nil, token, expectedIP)
}

func verifyClearanceMAC(mac hash.Hash, sumBuf []byte, token string, expectedIP string) error {
	body, sig, ok := strings.Cut(token, ".")
	if !ok || body == "" || sig == "" {
		return ErrInvalidToken
	}

	mac.Reset()
	mac.Write([]byte(body))
	expectedSig := mac.Sum(sumBuf)

	sigBytes, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil {
		return ErrBadSignature
	}
	if subtle.ConstantTimeCompare(expectedSig, sigBytes) != 1 {
		return ErrBadSignature
	}

	exp, tokenIP, err := decodeClearanceBody(body)
	if err != nil {
		return err
	}

	if time.Now().Unix() > exp {
		return ErrExpired
	}

	if expectedIP != "" {
		if tokenIP == "" || tokenIP != expectedIP {
			return ErrContextMismatch
		}
	}

	return nil
}

// ChallengeCookieMaxAge returns Max-Age seconds for challenge cookies (aligned with ChallengeLifetime).
func ChallengeCookieMaxAge() int {
	return int(ChallengeLifetime.Seconds())
}

// ClearanceCookieMaxAge returns Max-Age seconds for the clearance cookie.
func ClearanceCookieMaxAge() int {
	return int(ClearanceLifetime.Seconds())
}
