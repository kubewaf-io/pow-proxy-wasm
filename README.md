# pow-proxy-wasm

A lightweight, stateless browser challenge (Proof-of-Work) Proxy-WASM filter for Envoy / Istio / etc.

**Status: Alpha** — first public releases may change config, token formats, or APIs without a stability promise.

**Full documentation (kubeWAF docs site):** [pow-proxy-wasm](https://kubewaf.io/docs/pow-proxy-wasm) · source MDX: [`website/content/docs/pow-proxy-wasm/`](../website/content/docs/pow-proxy-wasm/)

**Language: Go** (using `proxy-wasm-go-sdk`, `GOOS=wasip1`). Builds to a stripped WASM module for Envoy V8.

**Module:** `github.com/kubewaf-io/pow-proxy-wasm` · **Image:** `ghcr.io/kubewaf-io/pow-proxy-wasm` · **License:** Apache-2.0

## Features

- Configurable + **dynamic** PoW challenge (difficulty = leading zero bits in SHA-256)
  - Static config: `base_difficulty` / `min_difficulty` / `max_difficulty`
  - Per-request override via `x-challenge-difficulty` header
  - Self-contained adaptive difficulty based on traffic pressure (local counter + periodic tick, low overhead)
- Fully stateless using HMAC-SHA256 (configurable secret)
- Self-contained challenge page (single-file HTML/JS, no external deps)
- Cookie-based solution (no extra POST/roundtrip)
- Optional extra response header injection via config
- Designed to run after rate limiting, before WAFs / auth

## Code quality & efficiency

- Minimized allocations and host calls in hot paths (cookie parsing, difficulty tracking uses local counters, shared data only on tick)
- Stripped WASM builds (`-ldflags=-s -w -trimpath`)
- Challenge page is aggressively optimized: pure-JS sync SHA-256 (no per-hash async overhead), minimal DOM/CSS, system dark/light theme
- Logging reduced in success paths (debug level for common verify)

## Configuration (plugin config JSON)

```json
{
  "header": "x-wasm-header",
  "value": "demo",
  "secret": "your-32+-byte-or-longer-hmac-secret-here-please-change",
  "base_difficulty": 18,
  "min_difficulty": 12,
  "max_difficulty": 26,
  "client_ip_source": "auto"
}
```

- `secret`: used for HMAC; **required**, ≥ 32 bytes, **must be the same across all replicas**. Plugin **fails to start** if missing or too short (no hardcoded default).
- `header` / `value`: optional response header injection.
- Difficulty bounds respected; dynamic pressure can bump up to +6 under load.
- `client_ip_source`: `auto` (default: `source.address` → XFF → X-Real-IP) or `source_address` (peer only; skips header hostcalls — best at the edge).

**Hot path (valid clearance):** one cookie scan → peer/IP resolve → fixed-layout HMAC verify (no JSON) → continue. Skips `connection.id` and HTTPS detection on pass-through.

Headers / cookies used (no "kubewaf" branding):
- Solve cookies (60s, aligned with challenge expiry): `challenge`, `challenge-sig`, `challenge-nonce`
- Access cookie (30 min, HttpOnly): `challenge-clearance`
- Fallback token header: `challenge-token`
- Override: `x-challenge-difficulty`

## Build

Requires **Go 1.24.x** (stock `gc` compiler — **not TinyGo**).

Go 1.25+ wasip1 pulls WASI imports (e.g. `path_filestat_get`) that Envoy’s Wasm host does not provide. The Makefile uses `-buildmode=c-shared` so the module is a reactor (`_initialize`) compatible with Envoy V8.

```bash
make build
# or manually:
# GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -ldflags="-s -w" -trimpath -o build/main.wasm .
```

Output: `build/main.wasm`

Other targets:
- `make oci` — build WASM + produce `build/pow-proxy-wasm.tar` (image tarball)
- `make oci-build` — build local Docker image (default: `ghcr.io/kubewaf-io/pow-proxy-wasm:latest`)
- `make publish` — build image and `docker push` (set `IMAGE=...` first; requires registry login)

See `make help`.

## Tests

```bash
# Unit tests + micro-benchmarks (no Docker)
make test

# Envoy integration (bats) — needs Docker + make build
make build
make test-bats

# k6: no-challenger vs challenger+valid-token + comparison PNG
make test-perf-k6-compare
# chart → test/perf/release-charts/baseline-vs-clearance.png

make test-perf-k6-ci    # CI smoke suite + same chart
```

| Suite | Command | What it covers |
|-------|---------|----------------|
| Unit | `make test-unit` | HMAC challenge/clearance, PoW, cookies, difficulty |
| Bench | `make test-bench` | generate/verify/cookie micro-benchmarks |
| Integration | `make test-bats` | Envoy + V8: 403 page, solve, clearance, header inject |
| Perf | `make test-perf-k6-compare` | Baseline (no WASM) vs clearance (valid token) + graph |

## Release

Push a `v*` tag to run [`.github/workflows/release.yml`](.github/workflows/release.yml):

1. Build `main.wasm` / OCI image → push `ghcr.io/<repo>:<tag>`
2. Attach `pow-proxy-wasm.wasm` + SHA256 to the GitHub Release
3. Run k6 perf smoke and embed overlay charts in release notes

CI on every PR/push: [`.github/workflows/test.yml`](.github/workflows/test.yml) (unit, build, bats, perf).

## Quick Verification

```bash
make build
cd example/envoy
docker compose down -v && docker compose up
```

Open http://localhost:8080 (or curl it).

- First hit (no cookie): returns the self-contained waiting/verification page (PoW auto-solved by browser JS using system theme).
- After solve + reload: passes through to backend.
- Subsequent: cookie validated, direct pass (stateless).

Inspect cookies in DevTools for `challenge*`.

See [example/envoy/README.md](example/envoy/README.md) for more.

## How it works (Signed Proof)

1. Request without valid proof → WASM issues 403 + signed challenge (HMAC) + HTML/JS page.
2. Browser JS solves PoW (sync SHA-256 loop, very fast) using difficulty from challenge.
3. On solve: sets `challenge-nonce` cookie, reloads.
4. WASM sees valid cookies (or `challenge-token` JSON) → verifies HMAC + PoW + expiry + IP context → issues `challenge-clearance` (30 min) and clears one-shot solve cookies → `ActionContinue`.
5. Later requests use clearance only (PoW solution is not the long-lived credential).
6. Dynamic difficulty: pressure tracked locally per filter, published on tick (5s), read with low overhead.

## Timers

| Credential | Lifetime | Notes |
|------------|----------|--------|
| Challenge + solve cookies | **60s** | Must match; cookie Max-Age == `ChallengeLifetime` |
| Clearance cookie | **30 min** | Issued after successful solve; HttpOnly; IP-bound |

## Client binding (IP + connection.id)

| Token | Bound to | Why |
|-------|----------|-----|
| Challenge / PoW solve | **IP** + Envoy **`connection.id`** (when available) | Same downstream connection as issue time |
| Clearance | **IP only** | Survives reload / new connections after a successful solve |

IP resolution order: Envoy `source.address` → left-most `X-Forwarded-For` → `X-Real-IP`. If unknown, IP context is empty (no forged `127.0.0.1`). Strip untrusted XFF at the edge.

`connection.id` is Envoy’s downstream connection identifier (not the TLS protocol session id — that attribute is not exposed to Wasm). The challenge page uses `fetch()` before reload so the solve can complete on the original connection; clearance then carries only the IP.

## Dark / Light theme

The waiting page automatically follows `prefers-color-scheme` (system / browser setting). No JS theme toggle needed. Clean, minimal, no fonts or external resources.

## Security notes

- `secret` is mandatory (≥ 32 bytes); never ship a shared default.
- Challenge/solve window is short (60s); access continues via clearance (30 min).
- Clearance is still a bearer cookie (shareable). IP binding reduces cross-client reuse; true one-time nonces would need shared state.
- Context binding uses connection peer / trusted XFF — configure Envoy hop trust correctly.
- This is a layer-7 challenge; combine with rate-limit, WAF, mTLS etc.

## Status

**Alpha.** Suitable for evaluation and early integration. Not a production stability commitment yet.

- Optimized for low memory/CPU on the clearance hot path and a tiny client payload
- Requires **Go 1.24.x** for Envoy-compatible Wasm builds (Go 1.25+ wasip1 imports unsupported WASI)
- Token format (fixed-layout clearance) and config keys may still evolve

Suggested first tag: `v0.1.0-alpha.1` (pre-releases do not update GHCR `:latest`).

Contributions and tuning of pressure heuristics welcome.
