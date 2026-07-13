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

The native client has no general public bearer-token option yet. Its
`FiduciaClient::internal(...)` constructor is exclusively for trusted
service-to-node calls: internal headers are debug-redacted and redirects are
refused so the secret cannot be replayed cross-origin. The separate
`clients/rust-wasm` client is generated for WebAssembly and supports explicit
default headers.
