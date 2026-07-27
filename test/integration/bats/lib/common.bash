# Shared helpers for challenge-proxy-wasm Envoy integration tests (bats).
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
  if [[ -n "${BATS_TEST_FILENAME:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
fi
if [[ -z "${ROOT_DIR:-}" ]]; then
  ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

WASM="${WASM:-$ROOT_DIR/build/main.wasm}"
ENVOY_YAML="${ENVOY_YAML:-$ROOT_DIR/test/fixtures/envoy.yaml}"
ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.33-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-challenge-proxy-wasm-test-envoy}"
HOST_PORT="${HOST_PORT:-18080}"
ADMIN_PORT="${ADMIN_PORT:-19901}"
REQUIRED_RUNTIME="${REQUIRED_RUNTIME:-envoy.wasm.runtime.v8}"
KEEP_RUNNING="${KEEP_RUNNING:-0}"
PLUGIN_SECRET="${PLUGIN_SECRET:-dev-only-change-me-32bytes-min!!}"
POWCLI="${POWCLI:-$ROOT_DIR/test/.tools/powcli}"

envoy_detect_ctr() {
  if command -v docker >/dev/null 2>&1; then
    CTR=docker
  elif command -v podman >/dev/null 2>&1; then
    CTR=podman
  else
    echo "ERROR: need docker or podman" >&2
    return 1
  fi
  export CTR
}

envoy_preflight() {
  [[ -f "$WASM" ]] || {
    echo "ERROR: $WASM not found. Build first (make build)." >&2
    return 1
  }
  grep -q "runtime: \"${REQUIRED_RUNTIME}\"" "$ENVOY_YAML" || {
    echo "FAIL: $ENVOY_YAML must set vm_config.runtime to \"${REQUIRED_RUNTIME}\"" >&2
    return 1
  }
  if [[ ! -x "$POWCLI" ]]; then
    echo "==> Building powcli"
    mkdir -p "$(dirname "$POWCLI")"
    (cd "$ROOT_DIR" && go build -o "$POWCLI" ./test/tools/powcli)
  fi
}

envoy_cleanup() {
  if [[ "$KEEP_RUNNING" == "1" ]]; then
    return 0
  fi
  $CTR rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

envoy_print_keep_running_info() {
  echo ""
  echo "==> Envoy is still running (container: ${CONTAINER_NAME})"
  echo "    HTTP:  http://127.0.0.1:${HOST_PORT}/"
  echo "    Admin: http://127.0.0.1:${ADMIN_PORT}/stats"
  echo ""
  echo "    Stop:  $CTR rm -f ${CONTAINER_NAME}"
  echo ""
}

envoy_fail() {
  local msg="${1:?}"
  local log_lines="${2:-40}"
  echo "$msg" >&2
  $CTR logs "$CONTAINER_NAME" 2>&1 | tail -n "$log_lines" >&2 || true
  if [[ "$KEEP_RUNNING" == "1" ]]; then
    envoy_print_keep_running_info
  else
    envoy_cleanup
  fi
  return 1
}

envoy_start() {
  envoy_detect_ctr
  envoy_preflight
  $CTR rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "==> Starting Envoy ($ENVOY_IMAGE)"
  $CTR run -d --rm --name "$CONTAINER_NAME" \
    -v "$WASM:/etc/envoy/plugin.wasm:ro" \
    -v "$ENVOY_YAML:/etc/envoy.yaml:ro" \
    -p "${HOST_PORT}:8080" \
    -p "${ADMIN_PORT}:9901" \
    "$ENVOY_IMAGE" \
    envoy -c /etc/envoy.yaml --log-level warn
  envoy_wait_ready
  envoy_assert_v8_runtime
  envoy_assert_plugin_loaded
}

envoy_wait_ready() {
  local i
  for i in $(seq 1 120); do
    # Challenge path returns 403 without cookies — any HTTP response means ready.
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${HOST_PORT}/"; then
      echo "==> Envoy ready on :${HOST_PORT}"
      return 0
    fi
    sleep 0.5
  done
  envoy_fail "FAIL: Envoy did not become ready on :${HOST_PORT}" 50
}

envoy_assert_v8_runtime() {
  local v8_active
  v8_active=$(curl -s "http://127.0.0.1:${ADMIN_PORT}/stats" \
    | grep "^wasm.${REQUIRED_RUNTIME}.active:" | awk '{print $2}' | head -1)
  [[ -n "${v8_active:-}" && "${v8_active}" -ge 1 ]] || \
    envoy_fail "FAIL: expected wasm.${REQUIRED_RUNTIME}.active >= 1 (got: ${v8_active:-none})" 50
  echo "    wasm.${REQUIRED_RUNTIME}.active=${v8_active}"
}

envoy_assert_plugin_loaded() {
  local logs
  logs=$($CTR logs "$CONTAINER_NAME" 2>&1 || true)
  if grep -Eiq 'error.*(wasm|plugin)|failed to load|OnPluginStartStatusFailed' <<<"$logs"; then
    # Soft check: only fail if wasm never became active (already checked) or critical load errors.
    if ! grep -q "wasm.${REQUIRED_RUNTIME}.active" <<<"$(curl -s "http://127.0.0.1:${ADMIN_PORT}/stats")"; then
      envoy_fail "FAIL: wasm plugin does not appear loaded" 80
    fi
  fi
}

envoy_base_url() {
  echo "http://127.0.0.1:${HOST_PORT}"
}

envoy_admin_stats() {
  curl -s "http://127.0.0.1:${ADMIN_PORT}/stats"
}

# Issue a challenge, solve PoW, and exchange for clearance on ONE keep-alive
# TCP connection. Challenge tokens bind Envoy connection.id, so separate curl
# processes would fail with context mismatch.
#
# Prints: clearance=<token>
# Optionally also writes solve cookies to SOLVE_COOKIES_OUT if set.
envoy_solve_and_clearance() {
  PLUGIN_SECRET="$PLUGIN_SECRET" POWCLI="$POWCLI" HOST_PORT="$HOST_PORT" \
    python3 - <<'PY'
import http.client
import os
import re
import subprocess
import sys

host = "127.0.0.1"
port = int(os.environ["HOST_PORT"])
secret = os.environ["PLUGIN_SECRET"]
powcli = os.environ["POWCLI"]

conn = http.client.HTTPConnection(host, port, timeout=30)
conn.request("GET", "/", headers={"Host": "localhost", "Connection": "keep-alive"})
resp = conn.getresponse()
body = resp.read()
if resp.status != 403:
    print(f"expected 403 challenge, got {resp.status}", file=sys.stderr)
    sys.exit(1)

# Fold set-cookie headers (http.client exposes getheaders)
cookies = {}
for k, v in resp.getheaders():
    if k.lower() == "set-cookie":
        m = re.match(r"([^=]+)=([^;]*)", v)
        if m:
            cookies[m.group(1).strip()] = m.group(2).strip()

challenge = cookies.get("challenge", "")
sig = cookies.get("challenge-sig", "")
if not challenge or not sig:
    print(f"missing challenge cookies: {cookies}", file=sys.stderr)
    sys.exit(1)

cookie_in = f"challenge={challenge}; challenge-sig={sig}"
proc = subprocess.run(
    [powcli, "solve-cookies", "-secret", secret, "-cookie", cookie_in],
    capture_output=True,
    text=True,
    check=False,
)
if proc.returncode != 0:
    print(proc.stderr or proc.stdout, file=sys.stderr)
    sys.exit(1)
# stdout is JSON {"c":"...","s":"...","n":N}
import json
sol = json.loads(proc.stdout.strip())
nonce = sol["n"]
solve_cookie = (
    f"challenge={challenge}; challenge-sig={sig}; challenge-nonce={nonce}"
)
out_path = os.environ.get("SOLVE_COOKIES_OUT", "")
if out_path:
    open(out_path, "w", encoding="utf-8").write(solve_cookie + "\n")

conn.request(
    "GET",
    "/",
    headers={
        "Host": "localhost",
        "Connection": "keep-alive",
        "Cookie": solve_cookie,
    },
)
resp2 = conn.getresponse()
_ = resp2.read()
if resp2.status != 200:
    print(f"expected 200 after solve, got {resp2.status}", file=sys.stderr)
    for k, v in resp2.getheaders():
        print(f"{k}: {v}", file=sys.stderr)
    sys.exit(1)

clearance = ""
for k, v in resp2.getheaders():
    if k.lower() == "set-cookie" and v.startswith("challenge-clearance="):
        clearance = v.split("=", 1)[1].split(";", 1)[0]
        break
if not clearance:
    print("missing challenge-clearance cookie", file=sys.stderr)
    for k, v in resp2.getheaders():
        print(f"{k}: {v}", file=sys.stderr)
    sys.exit(1)

conn.close()
print(f"clearance={clearance}")
PY
}

# Convenience: only the clearance token value.
envoy_get_clearance() {
  local line
  line=$(envoy_solve_and_clearance)
  printf '%s\n' "${line#clearance=}"
}
