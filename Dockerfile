# syntax=docker/dockerfile:1
FROM scratch
LABEL org.opencontainers.image.title="pow-proxy-wasm"
LABEL org.opencontainers.image.description="Lightweight Proxy-WASM browser challenge (PoW) filter"
LABEL org.opencontainers.image.source="https://github.com/kubewaf-io/pow-proxy-wasm"
LABEL org.opencontainers.image.licenses="Apache-2.0"
COPY build/main.wasm /plugin.wasm
