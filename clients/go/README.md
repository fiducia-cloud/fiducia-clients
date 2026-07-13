# Fiducia client (Go)

Zero-dependency Go HTTP client for [fiducia.cloud](https://fiducia.cloud), using only the standard library (`net/http`). Implements the shared `PROTOCOL.md` contract.

- `fiducia.go` — the production client generated from `templates/go.go.tmpl`
  plus `operations.json`; do not edit by hand.
- `locking.go` — hand-written handle helpers (`TryLockHandle`/`LockHandle`)
  layered on the generated raw-response API.
- `fiducia_test.go`, `locking_test.go` — tests. `go.mod` defines module `github.com/fiducia-cloud/fiducia-clients/clients/go`; `publish.sh` is the build/validate/release entrypoint.

There is no dedicated bearer-token field yet. Authenticated callers must set a
custom `http.Client`/`RoundTripper` on `Client.HTTP`.
