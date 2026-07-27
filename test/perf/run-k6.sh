#!/usr/bin/env bash
set -euo pipefail

# k6 performance harness for pow-proxy-wasm.
#
# Usage:
#   ./test/perf/run-k6.sh
#   PERF_PROFILE=baseline PERF_SCENARIO=baseline-get ./test/perf/run-k6.sh
#   PERF_PROFILE=challenge PERF_SCENARIO=clearance-get ./test/perf/run-k6.sh
#   ./test/perf/run-k6.sh --ci --all-smoke
#   ./test/perf/run-k6.sh --compare

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.k6.yml"

PERF_PROFILE="${PERF_PROFILE:-challenge}"
PERF_SCENARIO="${PERF_SCENARIO:-challenge-issue}"
PERF_VUS="${PERF_VUS:-32}"
PERF_DURATION="${PERF_DURATION:-60s}"
PERF_WARMUP="${PERF_WARMUP:-15s}"
PERF_P99_MS="${PERF_P99_MS:-200}"
PERF_FAIL_RATE="${PERF_FAIL_RATE:-0.01}"
PERF_HOST_PORT="${PERF_HOST_PORT:-18080}"
PERF_ADMIN_PORT="${PERF_ADMIN_PORT:-19901}"
PERF_ENVOY_CONTAINER="${PERF_ENVOY_CONTAINER:-pow-proxy-wasm-perf-envoy}"
# renovate: datasource=docker depName=envoyproxy/envoy versioning=loose
ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.33-latest}"
# renovate: datasource=docker depName=grafana/k6
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.57.0}"
KEEP_RUNNING="${KEEP_RUNNING:-0}"
PERF_CI="${PERF_CI:-0}"
RUN_COMPARE="${RUN_COMPARE:-0}"
PLUGIN_SECRET="${PLUGIN_SECRET:-dev-only-change-me-32bytes-min!!}"

WASM="${PERF_WASM:-$ROOT_DIR/build/main.wasm}"
POWCLI="${POWCLI:-$ROOT_DIR/test/.tools/powcli}"
RESULTS_DIR="$SCRIPT_DIR/results"
STAMP="${PERF_RUN_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
MEMORY_SAMPLER_PID=""
CLEARANCE_COOKIE="${CLEARANCE_COOKIE:-}"

VALID_PROFILES=(baseline challenge)
VALID_SCENARIOS=(baseline-get challenge-issue clearance-get)

usage() {
  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Profiles:  ${VALID_PROFILES[*]}"
  echo "Scenarios: ${VALID_SCENARIOS[*]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -k|--keep-running) KEEP_RUNNING=1 ;;
    --compare) RUN_COMPARE=1 ;;
    --ci) PERF_CI=1 ;;
    --all-smoke)
      PERF_CI=1
      RUN_ALL_SMOKE=1
      ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$PERF_CI" == "1" ]]; then
  PERF_DURATION="30s"
  PERF_WARMUP="10s"
  PERF_VUS="16"
  PERF_P99_MS="500"
fi

if command -v docker >/dev/null 2>&1; then
  CTR="docker"
  COMPOSE=(docker compose)
elif command -v podman >/dev/null 2>&1; then
  CTR="podman"
  if podman compose version >/dev/null 2>&1; then
    COMPOSE=(podman compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    echo "ERROR: need podman compose or docker-compose" >&2
    exit 1
  fi
else
  echo "ERROR: need docker or podman" >&2
  exit 1
fi

profile_valid=0
for p in "${VALID_PROFILES[@]}"; do
  [[ "$p" == "$PERF_PROFILE" ]] && profile_valid=1
done
[[ "$profile_valid" -eq 1 ]] || {
  echo "ERROR: invalid PERF_PROFILE=$PERF_PROFILE" >&2
  exit 2
}

scenario_valid=0
for s in "${VALID_SCENARIOS[@]}"; do
  [[ "$s" == "$PERF_SCENARIO" ]] && scenario_valid=1
done
[[ "$scenario_valid" -eq 1 ]] || {
  echo "ERROR: invalid PERF_SCENARIO=$PERF_SCENARIO" >&2
  exit 2
}

ensure_powcli() {
  if [[ ! -x "$POWCLI" ]]; then
    mkdir -p "$(dirname "$POWCLI")"
    (cd "$ROOT_DIR" && go build -o "$POWCLI" ./test/tools/powcli)
  fi
}

# When k6 shares Envoy's network namespace, peer IP is 127.0.0.1.
mint_clearance_for_local() {
  ensure_powcli
  "$POWCLI" mint-clearance -secret "$PLUGIN_SECRET" -ip "127.0.0.1"
}

cleanup_envoy() {
  if [[ "$KEEP_RUNNING" == "1" ]]; then
    return 0
  fi
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" rm -sf envoy >/dev/null 2>&1 || true
  $CTR rm -f "$PERF_ENVOY_CONTAINER" >/dev/null 2>&1 || true
}

trap 'stop_memory_sampler; cleanup_envoy' EXIT

start_memory_sampler() {
  local run_dir="$1"
  [[ -n "$CTR" ]] || return 0
  : > "$run_dir/memory-samples.log"
  (
    while true; do
      $CTR stats --no-stream --format '{{.MemUsage}}' "$PERF_ENVOY_CONTAINER" 2>/dev/null \
        >> "$run_dir/memory-samples.log" || true
      sleep 2
    done
  ) &
  MEMORY_SAMPLER_PID=$!
}

stop_memory_sampler() {
  if [[ -n "${MEMORY_SAMPLER_PID:-}" ]]; then
    kill "$MEMORY_SAMPLER_PID" 2>/dev/null || true
    wait "$MEMORY_SAMPLER_PID" 2>/dev/null || true
    MEMORY_SAMPLER_PID=""
  fi
}

run_dir_name() {
  local profile="$1"
  local scenario="$2"
  echo "run-${STAMP}-${profile}-${scenario}"
}

wait_for_envoy() {
  local i
  for i in $(seq 1 120); do
    if curl -sf "http://127.0.0.1:${PERF_ADMIN_PORT}/stats" >/dev/null 2>&1 \
        && curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PERF_HOST_PORT}/"; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Envoy HTTP/admin not ready on :${PERF_HOST_PORT}/:${PERF_ADMIN_PORT}" >&2
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" logs envoy 2>&1 | tail -30 >&2 || true
  return 1
}

LAST_RUN_DIR=""

run_one() {
  local profile="$1"
  local scenario="$2"
  local run_dir="$RESULTS_DIR/$(run_dir_name "$profile" "$scenario")"
  mkdir -p "$run_dir"
  LAST_RUN_DIR="$run_dir"

  # Docker cannot write to some host FS types (e.g. 9p virtio mounts under /data).
  # Stage k6 outputs on a local tmpfs path, then copy into $run_dir.
  local k6_stage
  k6_stage=$(mktemp -d /tmp/challenge-k6-XXXXXX)
  chmod 777 "$k6_stage"

  echo "==> Perf run: profile=${profile} scenario=${scenario}"
  echo "    vus=${PERF_VUS} duration=${PERF_DURATION} warmup=${PERF_WARMUP} p99<${PERF_P99_MS}ms"

  cleanup_envoy

  if [[ "$profile" != "baseline" && ! -f "$WASM" ]]; then
    echo "ERROR: $WASM not found. Build first: make build" >&2
    exit 1
  fi

  # baseline profile still mounts a dummy wasm path; use real wasm if present else empty file
  local wasm_mount="$WASM"
  if [[ "$profile" == "baseline" ]]; then
    if [[ ! -f "$WASM" ]]; then
      wasm_mount="$SCRIPT_DIR/.noop.wasm"
      touch "$wasm_mount"
    fi
  fi

  local clearance=""
  if [[ "$scenario" == "clearance-get" ]]; then
    clearance="${CLEARANCE_COOKIE:-}"
    if [[ -z "$clearance" ]]; then
      clearance="$(mint_clearance_for_local)"
    fi
    echo "    clearance cookie minted for 127.0.0.1 (${#clearance} bytes)"
  fi

  CHALLENGE_WASM="$wasm_mount" \
  PERF_PROFILE="$profile" \
  PERF_HOST_PORT="$PERF_HOST_PORT" \
  PERF_ADMIN_PORT="$PERF_ADMIN_PORT" \
  PERF_ENVOY_CONTAINER="$PERF_ENVOY_CONTAINER" \
  ENVOY_IMAGE="$ENVOY_IMAGE" \
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d envoy

  wait_for_envoy

  if [[ "$profile" != "baseline" ]]; then
    sleep 2
  fi

  ADMIN_URL="http://127.0.0.1:${PERF_ADMIN_PORT}" \
    "$SCRIPT_DIR/collect-stats.sh" before "$run_dir"

  local k6_quiet=()
  if [[ "$PERF_CI" == "1" ]]; then
    k6_quiet=(--quiet)
  fi

  local k6_env=(
    -e "BASE_URL=http://127.0.0.1:8080"
    -e "PERF_PROFILE=$profile"
    -e "PERF_SCENARIO=$scenario"
    -e "PERF_VUS=$PERF_VUS"
    -e "PERF_P99_MS=$PERF_P99_MS"
    -e "PERF_FAIL_RATE=$PERF_FAIL_RATE"
    -e "CLEARANCE_COOKIE=$clearance"
  )

  # grafana/k6 image runs as non-root; force root for staged results dir.
  local k6_user=(-u "0:0")

  if [[ "$PERF_WARMUP" != "0" && "$PERF_WARMUP" != "0s" ]]; then
    echo "==> Warmup (${PERF_WARMUP})..."
    $CTR run --rm --network "container:${PERF_ENVOY_CONTAINER}" \
      "${k6_user[@]}" \
      "${k6_env[@]}" \
      -e "PERF_DURATION=$PERF_WARMUP" \
      -e PERF_SKIP_FILE_EXPORT=1 \
      -v "$SCRIPT_DIR/k6:/scripts:ro" \
      -v "$k6_stage:/results" \
      "$K6_IMAGE" run "${k6_quiet[@]}" "/scripts/scenarios/${scenario}.js" >/dev/null \
      || { rm -rf "$k6_stage"; echo "ERROR: k6 warmup failed (profile=${profile})" >&2; return 1; }
  fi

  echo "==> k6 measured run..."
  start_memory_sampler "$run_dir"
  $CTR run --rm --network "container:${PERF_ENVOY_CONTAINER}" \
    "${k6_user[@]}" \
    "${k6_env[@]}" \
    -e "PERF_DURATION=$PERF_DURATION" \
    -v "$SCRIPT_DIR/k6:/scripts:ro" \
    -v "$k6_stage:/results" \
    "$K6_IMAGE" run "${k6_quiet[@]}" \
      --summary-export "/results/k6-summary.json" \
      "/scripts/scenarios/${scenario}.js" | tee "$run_dir/k6-stdout.txt"
  stop_memory_sampler

  # Copy staged k6 artifacts into the repo results tree (host-writable).
  cp -a "$k6_stage"/. "$run_dir"/ 2>/dev/null || true
  rm -rf "$k6_stage"

  ADMIN_URL="http://127.0.0.1:${PERF_ADMIN_PORT}" \
    "$SCRIPT_DIR/collect-stats.sh" after "$run_dir"
  chmod +x "$SCRIPT_DIR/finalize-memory.sh"
  PERF_ENVOY_CONTAINER="$PERF_ENVOY_CONTAINER" "$SCRIPT_DIR/finalize-memory.sh" "$run_dir"

  echo "==> Results: $run_dir"
  if [[ -f "$run_dir/k6-report.html" ]]; then
    echo "    HTML:  $run_dir/k6-report.html"
  fi
  if [[ ! -f "$run_dir/k6-summary.json" ]]; then
    echo "WARN: k6-summary.json missing under $run_dir" >&2
  fi

  if [[ "$KEEP_RUNNING" == "1" ]]; then
    trap - EXIT
    echo ""
    echo "==> Envoy still running (container: ${PERF_ENVOY_CONTAINER})"
    echo "    HTTP:  http://127.0.0.1:${PERF_HOST_PORT}/"
    echo "    Admin: http://127.0.0.1:${PERF_ADMIN_PORT}/stats"
  fi
}

render_compare_chart() {
  local left_dir="$1"
  local right_dir="$2"
  local charts_dir="${3:-$SCRIPT_DIR/release-charts}"
  mkdir -p "$charts_dir"

  if [[ ! -f "$left_dir/k6-summary.json" || ! -f "$right_dir/k6-summary.json" ]]; then
    echo "WARN: missing k6-summary.json; skip chart" >&2
    return 0
  fi

  # Prefer system matplotlib; fall back to stdout table only if unavailable.
  if ! python3 -c "import matplotlib" 2>/dev/null; then
    echo "WARN: matplotlib not installed — table only (pip install -r test/perf/requirements-charts.txt)" >&2
    return 0
  fi

  python3 "$SCRIPT_DIR/render-charts.py" compare \
    "$left_dir/k6-summary.json" \
    "$right_dir/k6-summary.json" \
    -o "$charts_dir/baseline-vs-clearance.png" \
    --left-label "No challenger" \
    --right-label "Challenger + valid token"

  # Alias for release notes / CI
  cp -f "$charts_dir/baseline-vs-clearance.png" "$charts_dir/perf-overlay.png" 2>/dev/null || true
  echo "==> Comparison chart: $charts_dir/baseline-vs-clearance.png"
}

compare_pair() {
  local left_profile="$1"
  local left_scenario="$2"
  local right_profile="$3"
  local right_scenario="$4"
  local left_dir right_dir

  echo "==> Comparing:"
  echo "    LEFT:  ${left_profile}/${left_scenario}  (no challenger)"
  echo "    RIGHT: ${right_profile}/${right_scenario}  (challenger + valid clearance token)"

  run_one "$left_profile" "$left_scenario"
  left_dir="$LAST_RUN_DIR"

  run_one "$right_profile" "$right_scenario"
  right_dir="$LAST_RUN_DIR"

  echo ""
  echo "==> Comparison table: no challenger vs valid token"
  python3 "$SCRIPT_DIR/compare-summaries.py" \
    "$left_dir/k6-summary.json" \
    "$right_dir/k6-summary.json" \
    --left-label "no-challenger" \
    --right-label "valid-token"

  render_compare_chart "$left_dir" "$right_dir"
}

if [[ "${RUN_ALL_SMOKE:-0}" == "1" ]]; then
  # CI: baseline + clearance (+ optional issue path), then force comparison chart
  run_one baseline baseline-get
  local_base="$LAST_RUN_DIR"
  run_one challenge clearance-get
  local_clear="$LAST_RUN_DIR"
  run_one challenge challenge-issue

  echo ""
  echo "==> Comparison table: no challenger vs valid token"
  python3 "$SCRIPT_DIR/compare-summaries.py" \
    "$local_base/k6-summary.json" \
    "$local_clear/k6-summary.json" \
    --left-label "no-challenger" \
    --right-label "valid-token"
  render_compare_chart "$local_base" "$local_clear"
  exit 0
fi

if [[ "$RUN_COMPARE" == "1" ]]; then
  # Primary perf comparison: Envoy only vs challenge filter with valid clearance cookie
  compare_pair baseline baseline-get challenge clearance-get
  exit 0
fi

run_one "$PERF_PROFILE" "$PERF_SCENARIO"
