#!/usr/bin/env bats
#
# Sliding renewal integration tests.
#
# Requires the feature to be enabled in the test fixture config:
#   test/fixtures/envoy.yaml → sliding_renewal_ttl: 10, renewal_ttl: 60.
# These cases mint clearances with powcli instead of solving PoW:
# clearance tokens are IP-bound only, so minting for the IP observed in a
# live challenge's ctx field is sufficient (no connection.id binding).

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

@test "clearance expired within renewal window passes through with fresh Set-Cookie" {
  ip=$(envoy_client_ip)
  tok=$("$POWCLI" mint-clearance -secret "$PLUGIN_SECRET" -ip "$ip" -expires-in -5s)
  hdr=$(mktemp)
  # Must fire within sliding_renewal_ttl (10s) of expiry — curl immediately.
  curl -sD "$hdr" -o /dev/null -b "challenge-clearance=${tok}" "$(envoy_base_url)/"
  [ "$(head -1 "$hdr" | awk '{print $2}')" = "200" ]
  grep -qiE '^set-cookie: challenge-clearance=.+max-age=60' "$hdr"
  grep -qiE '^set-cookie: challenge-clearance=.*httponly' "$hdr"
  rm -f "$hdr"
}

@test "renewed clearance cookie is itself valid on the next request" {
  ip=$(envoy_client_ip)
  tok=$("$POWCLI" mint-clearance -secret "$PLUGIN_SECRET" -ip "$ip" -expires-in -5s)
  hdr=$(mktemp)
  curl -sD "$hdr" -o /dev/null -b "challenge-clearance=${tok}" "$(envoy_base_url)/"
  renewed=$(grep -iE '^set-cookie: challenge-clearance=' "$hdr" \
    | sed 's/^[Ss]et-[Cc]ookie: challenge-clearance=\([^;]*\).*/\1/' | tr -d '\r' | head -1)
  [ -n "$renewed" ]
  rm -f "$hdr"
  run curl -s -o /dev/null -w "%{http_code}" \
    -b "challenge-clearance=${renewed}" "$(envoy_base_url)/"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}

@test "clearance expired beyond renewal window gets a fresh challenge (403)" {
  ip=$(envoy_client_ip)
  tok=$("$POWCLI" mint-clearance -secret "$PLUGIN_SECRET" -ip "$ip" -expires-in -60s)
  run curl -s -o /dev/null -w "%{http_code}" \
    -b "challenge-clearance=${tok}" "$(envoy_base_url)/"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "valid unexpired clearance still passes (hot path unaffected)" {
  tok=$("$POWCLI" mint-clearance -secret "$PLUGIN_SECRET" -ip "$(envoy_client_ip)")
  run curl -s -o /dev/null -w "%{http_code}" \
    -b "challenge-clearance=${tok}" "$(envoy_base_url)/"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}
