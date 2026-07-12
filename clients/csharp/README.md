# Fiducia C# / .NET client

Thin HTTP client SDK for the fiducia.cloud coordination service (locks, semaphores,
idempotency, config KV, rate limiting, cron, leader election, service discovery),
implementing the shared `PROTOCOL.md` contract.

- `Fiducia.cs` — the entire client: `Fiducia.FiduciaClient` plus `FiduciaException`
  (HTTP status >= 300) and `LockTimeoutException` (blocking-helper wait budget elapsed).
  Uses only the built-in `HttpClient` and `System.Text.Json` — no third-party deps.
- `Fiducia.Client.csproj` — NuGet package definition (`Fiducia.Client`, net6.0).
- `publish.sh` — build/validate/release entrypoint (see `clients/PUBLISHING.md`).
- `LICENSE.txt` — packaged with the NuGet artifact.
