# clients

One directory per language: the official Fiducia client libraries. Every client
is a thin, dependency-light HTTP wrapper over the single shared contract in
[`PROTOCOL.md`](../PROTOCOL.md), so they all expose the same operations (locks,
semaphores, idempotency keys, rate limiting, cron, KV, leader election, service
discovery) with a language-idiomatic surface.

The first production tier (`ts`, `python`, `go`, `rust`) is hand-maintained;
most other clients are generated from `operations.json` by `generate.py` so they
can't drift from the contract or each other. Each language folder owns a
`publish.sh` release entrypoint — see [`PUBLISHING.md`](PUBLISHING.md).
