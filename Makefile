# pow-proxy-wasm Makefile
# Build WASM, OCI image, tests, and publish

WASM := build/main.wasm
IMAGE ?= ghcr.io/kubewaf-io/pow-proxy-wasm:latest
DOCKER ?= docker

# renovate: datasource=docker depName=envoyproxy/envoy versioning=loose
ENVOY_IMAGE ?= envoyproxy/envoy:v1.33-latest

ROOT_DIR := $(abspath .)
TEST_DIR := $(ROOT_DIR)/test
TEST_TOOLS_DIR := $(TEST_DIR)/.tools
BATS_BIN := $(shell command -v bats 2>/dev/null)
ifeq ($(BATS_BIN),)
  BATS_BIN := $(TEST_TOOLS_DIR)/bats-core/bin/bats
endif
POWCLI := $(TEST_TOOLS_DIR)/powcli

CHARTS_VENV := $(TEST_TOOLS_DIR)/charts-venv
CHARTS_PYTHON := $(shell if [ -x "$(TEST_TOOLS_DIR)/charts-venv/bin/python3" ]; then echo "$(TEST_TOOLS_DIR)/charts-venv/bin/python3"; elif python3 -c "import matplotlib" 2>/dev/null; then echo python3; else echo "$(TEST_TOOLS_DIR)/charts-venv/bin/python3"; fi)

.PHONY: all build clean oci-build oci oci-tar publish help \
	test test-unit test-bench test-bats test-integration deps-test powcli \
	test-perf-k6 test-perf-k6-compare test-perf-k6-ci test-perf-charts deps-perf-charts

all: build

## Build the WASM plugin (stock Go wasip1 reactor for Envoy V8 — not TinyGo).
## -buildmode=c-shared emits _initialize (reactor) so Envoy does not run full WASI _start.
## Use Go 1.24.x: Go 1.25+ adds WASI imports Envoy does not implement (path_filestat_get).
build:
	mkdir -p build
	GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -ldflags="-s -w" -trimpath -o $(WASM) .
	@rm -f build/main.h
	@echo "Built $(WASM) ($$(wc -c < $(WASM)) bytes)"

## Remove build artifacts
clean:
	rm -rf build/ dist/ test/perf/results/run-* test/perf/release-charts/
	rm -f test/perf/.noop.wasm

## Build OCI image (requires Docker/BuildKit). Depends on WASM.
oci-build: build
	$(DOCKER) build -t $(IMAGE) -f Dockerfile .

## Build and export as image tarball (portable, loadable with docker load; compatible with OCI tooling)
oci-tar: build
	$(DOCKER) build -t $(IMAGE) -f Dockerfile .
	$(DOCKER) save -o build/pow-proxy-wasm.tar $(IMAGE)
	@echo "Image tarball: build/pow-proxy-wasm.tar (use: docker load -i build/pow-proxy-wasm.tar)"

## Alias for oci-tar (builds as OCI-compatible file)
oci: oci-tar

## Publish image to registry (requires login: docker login ghcr.io ...)
publish: oci-build
	$(DOCKER) push $(IMAGE)
	@echo "Published $(IMAGE)"

# --- Tests ---

deps-test:
	@bash $(TEST_DIR)/install-test-tools.sh

powcli:
	@mkdir -p $(TEST_TOOLS_DIR)
	go build -o $(POWCLI) ./test/tools/powcli

## Go unit tests (crypto, cookies, difficulty)
test-unit:
	go test ./... -count=1

## Go micro-benchmarks (smoke)
test-bench:
	go test ./... -bench=. -benchmem -run=^$$ -count=1

## Envoy + bats integration (needs build/main.wasm)
test-bats: deps-test powcli
	@test -f $(WASM) || (echo "ERROR: $(WASM) not found. Run: make build" >&2; exit 1)
	@test -x "$(BATS_BIN)" || (echo "ERROR: bats not found at $(BATS_BIN)" >&2; exit 1)
	HOST_PORT=$${HOST_PORT:-18080} ADMIN_PORT=$${ADMIN_PORT:-19901} \
	ENVOY_IMAGE=$(ENVOY_IMAGE) "$(BATS_BIN)" $(TEST_DIR)/integration/bats/

test-integration: test-bats

## k6 load test (PERF_PROFILE / PERF_SCENARIO)
test-perf-k6: powcli
	@chmod +x $(TEST_DIR)/perf/run-k6.sh $(TEST_DIR)/perf/collect-stats.sh \
		$(TEST_DIR)/perf/finalize-memory.sh
	ENVOY_IMAGE=$(ENVOY_IMAGE) $(TEST_DIR)/perf/run-k6.sh

## Compare no-challenger (baseline) vs challenger + valid clearance token + PNG chart
test-perf-k6-compare: powcli deps-perf-charts
	@test -f $(WASM) || (echo "ERROR: $(WASM) not found. Run: make build" >&2; exit 1)
	@chmod +x $(TEST_DIR)/perf/run-k6.sh $(TEST_DIR)/perf/collect-stats.sh \
		$(TEST_DIR)/perf/finalize-memory.sh $(TEST_DIR)/perf/render-charts.py
	ENVOY_IMAGE=$(ENVOY_IMAGE) $(TEST_DIR)/perf/run-k6.sh --compare
	@test -f $(TEST_DIR)/perf/release-charts/baseline-vs-clearance.png \
		|| $(MAKE) test-perf-charts
	@echo "==> Chart: $(TEST_DIR)/perf/release-charts/baseline-vs-clearance.png"

test-perf-k6-ci: powcli deps-perf-charts
	@test -f $(WASM) || (echo "ERROR: $(WASM) not found. Run: make build" >&2; exit 1)
	@chmod +x $(TEST_DIR)/perf/run-k6.sh $(TEST_DIR)/perf/collect-stats.sh \
		$(TEST_DIR)/perf/finalize-memory.sh $(TEST_DIR)/perf/render-charts.py
	ENVOY_IMAGE=$(ENVOY_IMAGE) PERF_CI=1 $(TEST_DIR)/perf/run-k6.sh --ci --all-smoke
	@$(CHARTS_PYTHON) $(TEST_DIR)/perf/render-charts.py bundle $(TEST_DIR)/perf/results \
		-o $(TEST_DIR)/perf/release-charts
	@test -f $(TEST_DIR)/perf/release-charts/baseline-vs-clearance.png

deps-perf-charts:
	@python3 -c "import matplotlib" 2>/dev/null && exit 0; \
	test -d $(CHARTS_VENV) || python3 -m venv $(CHARTS_VENV); \
	$(CHARTS_VENV)/bin/pip install -q -r $(TEST_DIR)/perf/requirements-charts.txt

test-perf-charts: deps-perf-charts
	@chmod +x $(TEST_DIR)/perf/render-charts.py
	@$(CHARTS_PYTHON) $(TEST_DIR)/perf/render-charts.py bundle $(TEST_DIR)/perf/results \
		-o $(TEST_DIR)/perf/release-charts
	@test -f $(TEST_DIR)/perf/release-charts/baseline-vs-clearance.png \
		|| test -f $(TEST_DIR)/perf/release-charts/perf-overlay.png
	@echo "==> Charts in $(TEST_DIR)/perf/release-charts/"

## unit + bench (no Docker)
test: test-unit test-bench

## Show help
help:
	@echo "Targets:"
	@echo "  make build              - compile WASM to build/main.wasm"
	@echo "  make oci                - build + export build/pow-proxy-wasm.tar"
	@echo "  make oci-build          - build local docker image $(IMAGE)"
	@echo "  make publish            - build and docker push $(IMAGE)"
	@echo "  make test               - unit tests + micro-benchmarks"
	@echo "  make test-unit          - go test"
	@echo "  make test-bench         - go test -bench"
	@echo "  make test-bats          - Envoy integration (needs make build + docker)"
	@echo "  make test-perf-k6       - k6 load test (PERF_PROFILE / PERF_SCENARIO)"
	@echo "  make test-perf-k6-compare - no-challenger vs valid-token + comparison PNG"
	@echo "  make test-perf-k6-ci    - k6 CI smoke + baseline-vs-clearance chart"
	@echo "  make test-perf-charts   - PNG charts from latest perf results"
	@echo "  make clean"
	@echo ""
	@echo "Override image: make IMAGE=myreg/foo:tag publish"
	@echo "Perf: PERF_PROFILE=challenge PERF_SCENARIO=clearance-get make test-perf-k6"
