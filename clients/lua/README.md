# fiducia-client (Lua)

Thin Lua HTTP client for the [fiducia.cloud](https://github.com/fiducia-cloud/fiducia-clients)
coordination API — distributed locks, semaphores, idempotency keys,
reader-writer locks, config KV, rate limiting, cron/scheduling, leader election,
and service discovery. It wraps the HTTP contract in [`PROTOCOL.md`](../../PROTOCOL.md);
application code only deals with keys, holders, and fencing tokens.

Transport is [luasocket](https://github.com/lunarmodules/luasocket) for `http://`
and [luasec](https://github.com/lunarmodules/luasec) for `https://` (chosen from
the URL scheme); JSON is encoded/decoded with [dkjson](http://dkolf.de/dkjson-lua/).

## Install

```sh
luarocks install fiducia-client
```

This pulls in `luasocket`, `luasec`, and `dkjson`. Requires Lua >= 5.1.

## Usage

```lua
local Fiducia = require("fiducia")
local c = Fiducia.new("https://api.fiducia.cloud")

-- Acquire, use, release a lock.
local grant = c:lock_acquire("orders/checkout", { holder = "worker-a", ttl_ms = 30000 })
local token = grant.result.output.fencing_token
-- ... do work guarded by the fencing token ...
c:lock_release("orders/checkout", "worker-a", token)
```

Each operation returns the decoded JSON response as a Lua table (or `nil` for an
empty body). Methods are called with `:` so they receive the client as `self`.

Optional named parameters are passed as a trailing `opts` table; only the fields
you set are sent (nil fields are omitted from the request body, which matters for
compare-and-set semantics). Booleans such as `wait` are always sent.

### Errors

On HTTP status `>= 300` — or a transport/TLS failure — the client raises a Lua
error whose value is a **table** `{ status = <number>, body = <parsed JSON | string> }`.
`status` is the numeric HTTP code; transport-level failures use `status = 0`.
Wrap calls in `pcall`:

```lua
local ok, res = pcall(function()
  return c:try_lock("orders/checkout", { holder = "worker-a", ttl_ms = 30000 })
end)
if ok then
  print("acquired:", res.result.output.acquired)
else
  print("failed: HTTP " .. tostring(res.status), res.body)
end
```

## Method reference

Optional params are shown inside the trailing `opts = { ... }` table.

**misc**
- `c:health()`
- `c:status()`

**locks**
- `c:lock_get(key)`
- `c:lock_acquire(key, { holder, ttl_ms, wait = true })`
- `c:lock_acquire_many(keys, { holder, ttl_ms, wait = true })` — `keys` is a string array (union lock)
- `c:try_lock(key, { holder, ttl_ms })` — `wait = false`
- `c:must_lock(key, { holder, ttl_ms })` / `c:lock(...)` — `wait = true`
- `c:lock_release(key, holder, fencing_token)` — `key` is accepted for symmetry but not sent

**semaphores**
- `c:semaphore_get(key)`
- `c:semaphore_acquire(key, limit, { holder, ttl_ms, wait = true })`
- `c:try_semaphore(key, limit, { holder, ttl_ms })` — `wait = false`
- `c:must_semaphore(key, limit, { holder, ttl_ms })` / `c:semaphore(...)` — `wait = true`
- `c:semaphore_release(key, holder, fencing_token)`

**idempotency**
- `c:idempotency_get(key)`
- `c:idempotency_claim(key, { owner, ttl_ms, ttl, metadata })` — `metadata` is an arbitrary JSON object
- `c:idempotency_complete(key, owner, fencing_token, result)` — `result` (optional) is an arbitrary JSON object

**reader-writer locks**
- `c:rw_acquire_read(key, { ttl_ms, wait = true })`
- `c:rw_end_read(key, lock_id)`
- `c:rw_acquire_write(key, { ttl_ms, wait = true })`
- `c:rw_end_write(key, lock_id)`

**config KV**
- `c:kv_get(key)`
- `c:kv_put(key, value, { ttl_ms, prev_revision })` — `value` is arbitrary JSON
- `c:kv_delete(key)`
- `c:kv_list(prefix)`

**rate limiting**
- `c:rate_limit_get(tenant, key)`
- `c:rate_limit_check(tenant, key, algorithm, limit, window_ms, { refill_per_second, cost })`

**cron & scheduling**
- `c:schedule_get(name)`
- `c:schedule_upsert(name, target, { cron, one_shot_at_ms, delivery, max_retries })` — `target` is an arbitrary JSON object
- `c:schedule_record_run(name, fire_id, fired_at_ms)`
- `c:schedule_history(name)`

**leader election**
- `c:election_get(name)`
- `c:election_campaign(name, candidate, ttl_ms, metadata)`
- `c:election_renew(name, candidate, fencing_token)`
- `c:election_resign(name, candidate, fencing_token)`

**service discovery**
- `c:service_instances(service)`
- `c:service_register(service, instance_id, address, ttl_ms, metadata)`
- `c:service_heartbeat(service, instance_id, ttl_ms)`
- `c:service_deregister(service, instance_id)`
- `c:service_list()`

## Notes

- **Thin by design.** The `try_*` / `must_*` / `lock` / `semaphore` helpers only
  flip the `wait` flag on the corresponding acquire call — there is no
  client-side wait/poll loop.
- **TLS** uses luasec's default parameters for the `https` convenience module;
  certificate verification depends on your luasec build and system CA store.

## License

Proprietary. See [`../../PROTOCOL.md`](../../PROTOCOL.md) and repository terms.
