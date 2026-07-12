# Fiducia F# / .NET client

Thin HTTP client SDK for the fiducia.cloud coordination service (locks, semaphores,
idempotency, config KV, rate limiting, cron, leader election, service discovery),
implementing the shared `PROTOCOL.md` contract.

- `Fiducia.fs` — the entire client: `Fiducia.FiduciaClient` plus `FiduciaError`
  (HTTP status >= 300). Uses only the built-in `HttpClient` and `System.Text.Json`
  (`JsonNode`) — no third-party deps.
- `Fiducia.FSharp.Client.fsproj` — NuGet package definition (`Fiducia.FSharp.Client`, net6.0).
- `publish.sh` — build/validate/release entrypoint (see `clients/PUBLISHING.md`).
- `LICENSE.txt` — packaged with the NuGet artifact.
