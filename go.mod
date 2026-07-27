module github.com/kubewaf-io/pow-proxy-wasm

// Go 1.25+ wasip1 pulls WASI imports (e.g. path_filestat_get) that Envoy's
// Wasm host does not provide. Pin 1.24 for Envoy-compatible WASM builds.
// Unit tests still run on newer toolchains via GOTOOLCHAIN if needed.
go 1.24

require (
	github.com/proxy-wasm/proxy-wasm-go-sdk v0.0.0-20260105142703-44c7d5847745
	github.com/tidwall/gjson v1.19.0
)

require (
	github.com/tidwall/match v1.1.1 // indirect
	github.com/tidwall/pretty v1.2.0 // indirect
)
