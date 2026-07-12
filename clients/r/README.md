# Fiducia (R)

The `fiducia.client` R package: a dependency-light HTTP client for
fiducia.cloud built on `httr` (transport) and `jsonlite` (JSON). Implements the
shared `PROTOCOL.md` contract over locks, semaphores, reader-writer locks,
idempotency, config KV, rate limiting, cron, leader election, and service
discovery.

- `R/fiducia.R` — the client source (S3 `fiducia_client` object + one exported
  function per operation).
- `DESCRIPTION` / `NAMESPACE` — package metadata and hand-maintained exports.
- `publish.sh` — `R CMD check`/`build` validate-and-release entrypoint (see
  `clients/PUBLISHING.md`).
