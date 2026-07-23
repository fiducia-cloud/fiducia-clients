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

The native client supports `FiduciaClient::bearer(...)` for API-key calls to
the edge/load balancer and `FiduciaClient::internal(...)` exclusively for
trusted service-to-node calls. Both credential forms are debug-redacted,
refuse redirects, and reject cleartext public hosts before sending a request.
The separate `clients/rust-wasm` client is generated for WebAssembly and
supports explicit default headers.

`sync_write()` and `sync_pull()` use the generated
`types::SyncQueuedWrite`, `types::SyncWriteAcknowledgement`, and
`types::SyncPullPage` contracts. Sync writes always reuse the canonical
`write.key` as `Idempotency-Key`, so retries remain safe for a durable
fiducia-sync queue.
