# Fiducia (PowerShell)

Fiducia HTTP client for PowerShell 5.1+, built on `Invoke-RestMethod` with no
external modules. Implements the shared `PROTOCOL.md` contract (locks,
semaphores, idempotency, KV, rate limiting, cron, leader election, service
discovery).

- `Fiducia.psm1` — the module: a `FiduciaClient` class exposing one method per
  protocol operation, plus retry/timeout handling.
- `Fiducia.psd1` — the module manifest (version, metadata, PSGallery tags).
- `publish.sh` — validate the manifest and publish to the PowerShell Gallery
  (see `clients/PUBLISHING.md`).
