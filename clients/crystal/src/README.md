# Crystal client source

`fiducia.cr` — the whole Crystal client in one file. It defines the `Fiducia` module
(`Fiducia::Client`, plus `Fiducia::Error` for HTTP status >= 300 and `Fiducia::Timeout`
for the blocking acquire helpers). Zero third-party dependencies: only the stdlib
`HTTP::Client`, `JSON`, and `URI`. Every method returns the parsed JSON response as a
`JSON::Any`, implementing the shared `PROTOCOL.md` contract for locks, semaphores,
idempotency, KV, rate limiting, cron, elections, and service discovery.
