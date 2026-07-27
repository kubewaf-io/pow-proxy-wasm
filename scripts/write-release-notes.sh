#!/usr/bin/env bash
# Build release-notes.md for GitHub Releases: conventional-commit changelog + perf charts.
# Usage: write-release-notes.sh [out.md] [charts_dir] [conventional-changelog.md]
set -euo pipefail

OUT="${1:-release-notes.md}"
CHARTS_DIR="${2:-test/perf/release-charts}"
CHANGELOG_FILE="${3:-}"
REPO="${GITHUB_REPOSITORY:-owner/repo}"
TAG="${GITHUB_REF_NAME:-v0.0.0}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

chart_url() {
  local file="$1"
  echo "${BASE}/${file}"
}

emit_section() {
  local title="$1"
  local file="$2"
  if [[ -f "${CHARTS_DIR}/${file}" ]]; then
    printf '### %s\n\n' "$title"
    printf '![%s](%s)\n\n' "$title" "$(chart_url "$file")"
  fi
}

{
  echo "## pow-proxy-wasm ${TAG}"
  echo ""
  if [[ "${TAG}" == *alpha* || "${TAG}" == *beta* || "${TAG}" == *rc* ]]; then
    echo "> **Pre-release:** config, token formats, and APIs may change without a stability guarantee."
    echo ""
  fi
  echo "Artifacts: \`pow-proxy-wasm.wasm\` (Envoy proxy-wasm / V8; also as \`main.wasm\`) and SHA256 checksum."
  echo ""
  echo "Requires **Go 1.24.x** to rebuild Wasm. Envoy V8 runtime."
  echo ""
  echo "## OCI image"
  echo ""
  echo "Container image: \`ghcr.io/${REPO}:${TAG}\` (also \`:${TAG#v}\` without the \`v\` prefix)."
  echo "Pre-releases do **not** update \`:latest\`."
  echo ""
  echo '```bash'
  echo "make oci-build IMAGE=ghcr.io/${REPO}:${TAG}"
  echo "docker pull ghcr.io/${REPO}:${TAG}"
  echo '```'
  echo ""
  if [[ -n "${CHANGELOG_FILE}" && -f "${CHANGELOG_FILE}" && -s "${CHANGELOG_FILE}" ]]; then
    echo "## What's changed since last release"
    echo ""
    cat "${CHANGELOG_FILE}"
    echo ""
  fi
  echo "## Performance benchmarks"
  echo ""
  echo "k6 through Envoy comparing **no challenger** (baseline router only) vs **challenger + valid clearance token**."
  echo ""
  emit_section "No challenger vs valid token" "baseline-vs-clearance.png"
  emit_section "No challenger vs valid token" "perf-overlay.png"
  emit_section "Memory — container RSS" "memory-overlay.png"
  echo "## Known limitations (alpha)"
  echo ""
  echo "- Clearance is a bearer cookie with IP binding (not one-time / not cluster-shared anti-replay)."
  echo "- Fail-open if challenge generation fails (RNG/crypto)."
  echo "- Adaptive difficulty is per-filter heuristic, not global."
  echo "- Stock Go Wasm binary is relatively large (~4 MiB); use Go 1.24 for Envoy-compatible builds."
  echo ""
} >"$OUT"

echo "==> Wrote $OUT"
