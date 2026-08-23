# Fiducia (Rust)

Thin, blocking HTTP client for fiducia.cloud built on `ureq` + `serde_json`.
Implements the shared `PROTOCOL.md` contract. Re-exports the generated
`fiducia-interfaces` payload/error types (as `types`) so responses can be
deserialized into typed structs.

- `src/` — the client crate (`lib.rs` transport + operations, `locking.rs`
  high-level lock/semaphore ergonomics, `asynchronous.rs` the async client).
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

## Async callers

`FiduciaClient` is blocking, so calling it from an axum/tokio service parks a
runtime thread on every lock and rate-limit call — on the request path. That
cost pushed async services into re-implementing the protocol against raw HTTP,
and those hand-rolled clients shipped the exact defects this crate avoids: no
renew heartbeat, and `not_leader` treated as fatal.

Enable the `async` feature for `AsyncFiduciaClient`, a `reqwest`-backed twin
carrying the same invariants — credential-aware cleartext refusal, no
redirects, retry only what is provably safe, `renewed: false` as lost fenced
authority, and outcomes read from `result.output`.

```toml
fiducia-client = { version = "0.1", features = ["async"] }
```

```rust
use fiducia_client::AsyncFiduciaClient;

let fiducia = AsyncFiduciaClient::internal(&node_url, &secret, &org_id);

// A lease is a deadline, not a mutex: heartbeat it and stop on lost authority.
if let Some(token) = fiducia.acquire("nightly-rollup", &holder, 120_000).await? {
    let mut ticker = tokio::time::interval(Duration::from_millis(40_000));
    loop {
        tokio::select! {
            _ = ticker.tick() => {
                // Err here means fiducia already reaped the grant — cancel the work.
                fiducia.renew("nightly-rollup", &holder, token, 120_000).await?;
            }
            done = &mut job => break done,
        }
    }
    fiducia.release("nightly-rollup", &holder, token).await?;
}
```

The behaviour above is pinned by `tests/async_conformance.rs`, which is also the
executable form of the "integrating a client correctly" checklist in
`PROTOCOL.md`:

```
cargo test -p fiducia-client --features async --test async_conformance
```
