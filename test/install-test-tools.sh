#!/usr/bin/env bash
# Fetch bats-core into test/.tools/ when not installed system-wide.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/.tools"

# renovate: datasource=github-tags depName=bats-core/bats-core versioning=semver-coerced
BATS_VERSION="${BATS_VERSION:-v1.11.1}"

install_bats() {
  if command -v bats >/dev/null 2>&1; then
    echo "==> bats already available: $(command -v bats)"
    return 0
  fi
  local dir="$TOOLS_DIR/bats-core"
  if [[ -x "$dir/bin/bats" ]]; then
    echo "==> bats already installed at $dir/bin/bats"
    return 0
  fi
  echo "==> Installing bats-core $BATS_VERSION"
  rm -rf "$dir"
  git clone --depth 1 --branch "$BATS_VERSION" \
    https://github.com/bats-core/bats-core.git "$dir"
  echo "==> bats: $dir/bin/bats"
}

mkdir -p "$TOOLS_DIR"
install_bats
