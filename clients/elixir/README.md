# Fiducia Elixir client

Thin HTTP client SDK for the fiducia.cloud coordination service (locks, semaphores,
idempotency, config KV, rate limiting, cron, leader election, service discovery),
implementing the shared `PROTOCOL.md` contract.

- `fiducia.ex` — the entire client, `Fiducia.Client`. Stdlib only: `:httpc` (inets) for
  transport and `:json` (OTP 27+) for JSON; no third-party deps. Start `:inets`/`:ssl`,
  build a client with `Fiducia.Client.new/2`, then pass it first to every operation.
- `mix.exs` — Hex package definition (`:fiducia_client`).
- `publish.sh` — build/validate/release entrypoint (see `clients/PUBLISHING.md`).
