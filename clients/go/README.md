# Fiducia client (Go)

Zero-dependency Go HTTP client for [fiducia.cloud](https://fiducia.cloud), using only the standard library (`net/http`). Implements the shared `PROTOCOL.md` contract.

- `fiducia.go` — the thin generated client (from `operations.json` via `generate.py`); do not edit by hand.
- `locking.go` — hand-written live-mutex-style helpers (`TryLock`/`Lock`) layered on the generated client.
- `fiducia_test.go`, `locking_test.go` — tests. `go.mod` defines module `github.com/fiducia-cloud/fiducia-clients/clients/go`; `publish.sh` is the build/validate/release entrypoint.
