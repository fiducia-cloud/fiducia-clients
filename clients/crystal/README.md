# Fiducia (Crystal)

Fiducia HTTP client for Crystal. Zero-dependency — the standard library's
`HTTP::Client` + `JSON`. Implements `PROTOCOL.md`.

## Install

Shards. There is no central registry — depend on the git tag directly:

```yaml
# shard.yml
dependencies:
  fiducia-client:
    github: fiducia-cloud/fiducia-clients
    tag: clients/crystal/v0.1.0
```

Then `shards install` and require the client:

```crystal
require "fiducia-client/fiducia"
```

The client is a single self-contained, dependency-free file, so you can also
just vendor `src/fiducia.cr` into your project and `require "./fiducia"`.

## Usage

Every method returns the parsed JSON response as a `JSON::Any` (a `Hash`,
`Array`, number, string, or a null `JSON::Any`). An empty body decodes to a null
`JSON::Any`. On HTTP status ≥ 300 a `Fiducia::Error` is raised.

```crystal
require "fiducia-client/fiducia"

c = Fiducia::Client.new("https://api.fiducia.cloud")

# Acquire and release a lock.
grant = c.lock_acquire("orders/checkout", holder: "worker-a", ttl_ms: 30_000)
token = grant["result"]["output"]["fencing_token"].as_i64
c.lock_release("orders/checkout", "worker-a", token)

# Config KV.
c.kv_put("features/beta", "on", ttl_ms: 60_000)
entry = c.kv_get("features/beta")

# Arbitrary-JSON params (metadata / target / result) are passed as JSON::Any.
c.election_campaign("primary", "node-1", 15_000, metadata: JSON.parse(%({"region":"us-east"})))

begin
  c.status
rescue err : Fiducia::Error
  puts "HTTP #{err.status}: #{err.body}"
end
```

### Method surface

`health` · `status` · `lock_get` · `lock_acquire` · `lock_acquire_many` ·
`try_lock` · `must_lock` · `lock` · `lock_release` · `semaphore_get` ·
`semaphore_acquire` · `try_semaphore` · `must_semaphore` · `semaphore` ·
`semaphore_release` · `idempotency_get` · `idempotency_claim` ·
`idempotency_complete` · `rw_acquire_read` · `rw_end_read` · `rw_acquire_write` ·
`rw_end_write` · `kv_get` · `kv_put` · `kv_delete` · `kv_list` · `rate_limit_get` ·
`rate_limit_check` · `schedule_get` · `schedule_upsert` · `schedule_record_run` ·
`schedule_history` · `election_get` · `election_campaign` · `election_renew` ·
`election_resign` · `service_list` · `service_instances` · `service_register` ·
`service_heartbeat` · `service_deregister`

Optional parameters (`holder`, `ttl_ms`, `metadata`, …) are omitted from the
request body when `nil`, which preserves compare-and-set semantics.

`try_lock` / `try_semaphore` are single-shot (`wait: false`) and return the raw
acquire result. `must_lock` / `lock` and `must_semaphore` / `semaphore` **block
until the grant is actually held**: the server reserves a FIFO slot and returns
immediately rather than holding the connection, so these helpers poll
`lock_get` / `semaphore_get` until you own it, then return a normalized held
grant — a `JSON::Any` of `{holder, fencing_token, lease_expires_ms}` you can pass
to `lock_release` / `semaphore_release`. They accept `max_wait_ms` (default
`30_000`), `retry_interval_ms` (default `250`), and an optional `max_retries`,
and raise `Fiducia::Timeout` if the wait budget elapses before the grant is held
(a stable `"fdc-…"` holder is generated when you don't supply one).

Constructor options: `Fiducia::Client.new(base_url, request_timeout : Time::Span? = nil)`
— pass a per-request `request_timeout` (e.g. `5.seconds`) if you need one.

## License

Proprietary / `UNLICENSED`. No open-source license has been granted for this
package yet. All rights reserved unless fiducia.cloud grants a separate license.
