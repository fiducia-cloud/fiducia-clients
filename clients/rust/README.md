# Fiducia (Rust)

Thin, blocking HTTP client for fiducia.cloud built on `ureq` + `serde_json`.
Implements the shared `PROTOCOL.md` contract. Re-exports the generated
`fiducia-interfaces` payload/error types (as `types`) so responses can be
deserialized into typed structs.

- `src/` — the client crate (`lib.rs` transport + operations, `locking.rs`
  high-level lock/semaphore ergonomics).
- `Cargo.toml` — crate manifest.
- `publish.sh` — `cargo package`/`publish` release entrypoint (see
  `clients/PUBLISHING.md`).

This crate is also the source compiled to WebAssembly in `clients/rust-wasm`.
