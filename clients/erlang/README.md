# Fiducia Erlang client

Thin, dependency-light HTTP client SDK for the fiducia.cloud coordination service
(locks, semaphores, idempotency, config KV, rate limiting, cron, leader election,
service discovery), implementing the shared `PROTOCOL.md` contract. Requires OTP 27+
(uses the stdlib `json` module); transport is `httpc` (inets). No third-party runtime deps.

- `src/` — the client module and OTP application metadata (`fiducia.erl`,
  `fiducia_client.app.src`).
- `rebar.config` — build config and Hex publish setup (via `rebar3_hex`).
- `publish.sh` — build/validate/release entrypoint (see `clients/PUBLISHING.md`).
