# Rust-WASM client sources

`lib.rs` — the Fiducia WebAssembly client, generated from `operations.json` by
`generate.py` (do not edit by hand). Uses `wasm-bindgen` to export one `async`
method per `PROTOCOL.md` operation to JavaScript, with the global `fetch` as
transport and `AbortSignal.timeout` for per-request deadlines.
