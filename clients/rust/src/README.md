# Rust client sources

- `lib.rs` — the `FiduciaClient`: `ureq`-based transport, retry/timeout
  handling, and one method per `PROTOCOL.md` operation. Re-exports
  `fiducia-interfaces` as `types` for typed response deserialization.
- `locking.rs` — hand-written, live-mutex-style lock and semaphore handles
  (`try`/blocking acquire, fencing tokens, RAII release) layered on the client.
