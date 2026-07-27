#!/usr/bin/env bats

load lib/common

setup_file() {
  envoy_start
}

teardown_file() {
  if [[ "${KEEP_RUNNING:-0}" != "1" ]]; then
    envoy_cleanup
  else
    envoy_print_keep_running_info
  fi
}

@test "unauthenticated GET returns 403 challenge page" {
  run curl -s -o /tmp/challenge-body.html -w "%{http_code}" "$(envoy_base_url)/"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
  run grep -Eqi "challenge|sha-?256|difficulty|nonce" /tmp/challenge-body.html
  [ "$status" -eq 0 ]
}

@test "challenge response sets challenge cookies" {
  hdr=$(mktemp)
  curl -sD "$hdr" -o /dev/null "$(envoy_base_url)/"
  grep -qi 'set-cookie: challenge=' "$hdr"
  grep -qi 'set-cookie: challenge-sig=' "$hdr"
  rm -f "$hdr"
}

@test "valid PoW solution on same connection returns 200 and issues clearance" {
  line=$(envoy_solve_and_clearance)
  [[ "$line" == clearance=* ]]
  clearance="${line#clearance=}"
  [ -n "$clearance" ]
}

@test "clearance cookie allows subsequent request without re-solving" {
  clearance=$(envoy_get_clearance)
  run curl -s -o /dev/null -w "%{http_code}" \
    -b "challenge-clearance=${clearance}" \
    "$(envoy_base_url)/"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}

@test "invalid clearance is rejected with 403" {
  run curl -s -o /dev/null -w "%{http_code}" \
    -b "challenge-clearance=not-a-valid-token" \
    "$(envoy_base_url)/"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "x-challenge-difficulty override is respected in payload" {
  hdr=$(mktemp)
  curl -sD "$hdr" -o /dev/null -H "x-challenge-difficulty: 6" "$(envoy_base_url)/"
  challenge=$(grep -i '^set-cookie: challenge=' "$hdr" \
    | sed 's/[Ss]et-[Cc]ookie: challenge=\([^;]*\).*/\1/' | tr -d '\r' | head -1)
  [ -n "$challenge" ]
  diff=$(python3 - "$challenge" <<'PY'
import base64, json, sys
s = sys.argv[1]
pad = "=" * (-len(s) % 4)
raw = base64.urlsafe_b64decode(s + pad)
print(json.loads(raw)["diff"])
PY
)
  [ "$diff" = "6" ]
  rm -f "$hdr"
}

@test "response header injection from plugin config" {
  # After clearance, optional x-wasm-header should appear on backend response.
  clearance=$(envoy_get_clearance)
  hdr=$(mktemp)
  curl -sD "$hdr" -o /dev/null -b "challenge-clearance=${clearance}" "$(envoy_base_url)/"
  grep -qi 'x-wasm-header: demo-wasm' "$hdr"
  rm -f "$hdr"
}

@test "wasm v8 runtime remains active" {
  stats=$(envoy_admin_stats)
  active=$(grep "^wasm.envoy.wasm.runtime.v8.active:" <<<"$stats" | awk '{print $2}' | head -1)
  [ -n "$active" ]
  [ "$active" -ge 1 ]
}
