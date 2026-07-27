# Performance tests (k6)

Load-test [pow-proxy-wasm](../../) through Envoy with [Grafana k6](https://k6.io/).

## Prerequisites

- `docker` or `podman` (+ compose)
- `build/main.wasm` (`make build`)
- Go (to build `test/tools/powcli` for clearance minting)
- Ports `18080` (HTTP) and `19901` (admin) free

## Quick start

```bash
make build

# Primary comparison: no challenger vs challenger with valid clearance token
# Produces test/perf/release-charts/baseline-vs-clearance.png
make test-perf-k6-compare

# Individual runs
PERF_PROFILE=baseline PERF_SCENARIO=baseline-get make test-perf-k6
PERF_PROFILE=challenge PERF_SCENARIO=clearance-get make test-perf-k6
PERF_PROFILE=challenge PERF_SCENARIO=challenge-issue make test-perf-k6

make test-perf-k6-ci           # CI smoke + comparison chart
make test-perf-charts          # re-render charts from existing results
```

### Comparison chart

`make test-perf-k6-compare` (and CI) always contrasts:

| Side | Profile / scenario | Meaning |
|------|--------------------|---------|
| **No challenger** | `baseline` / `baseline-get` | Envoy router only (no WASM filter) |
| **Valid token** | `challenge` / `clearance-get` | Plugin on + signed `challenge-clearance` cookie |

Output PNG: `test/perf/release-charts/baseline-vs-clearance.png`

- Left panel: latency p50 / p90 / p95 / p99 (grouped bars)
- Right panel: throughput (req/s)
- Caption: RPS % delta and p50 delta

## Profiles

| Profile | Filter | Notes |
|---------|--------|-------|
| `baseline` | none | Envoy router + direct_response floor |
| `challenge` | pow-proxy-wasm | Low difficulty (8) for fast CI solves |

Configs: `test/perf/profiles/`.

## Scenarios

| Scenario | Traffic | Expected |
|----------|---------|----------|
| `baseline-get` | `GET /` | 200 |
| `challenge-issue` | `GET /` unauthenticated | 403 + challenge page |
| `clearance-get` | `GET /` + `challenge-clearance` cookie | 200 |

Clearance cookies are minted by `powcli` for `127.0.0.1` (k6 shares Envoy’s network namespace).

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PERF_PROFILE` | `challenge` | Envoy profile |
| `PERF_SCENARIO` | `challenge-issue` | k6 script name |
| `PERF_VUS` | `32` | Virtual users |
| `PERF_DURATION` | `60s` | Measured run |
| `PERF_WARMUP` | `15s` | Warmup (`0` to skip) |
| `PERF_P99_MS` | `200` | k6 p99 threshold |
| `PERF_HOST_PORT` | `18080` | HTTP port |
| `PERF_ADMIN_PORT` | `19901` | Admin port |
| `ENVOY_IMAGE` | `envoyproxy/envoy:v1.33-latest` | Envoy pin |

CI (`PERF_CI=1`): 30s measured, 10s warmup, 16 VUs, p99 threshold 500ms.

## Output

Each run: `test/perf/results/run-<timestamp>-<profile>-<scenario>/`

- `k6-summary.json`, `k6-stdout.txt`, `k6-report.html`
- `envoy-stats-*.txt`, `memory-snapshot.json`

```bash
make test-perf-charts   # → test/perf/release-charts/perf-overlay.png
```
