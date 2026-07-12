# Fiducia (Ruby)

Zero-dependency Ruby client for fiducia.cloud, built on stdlib `net/http` +
`json`. Implements the shared `PROTOCOL.md` contract (locks, semaphores,
idempotency, KV, rate limiting, cron, leader election, service discovery).

- `fiducia.rb` — the client (`Fiducia::Client`, one method per operation).
- `fiducia-client.gemspec` — gem packaging manifest.
- `publish.sh` — build/validate/push the gem (see `clients/PUBLISHING.md`).
