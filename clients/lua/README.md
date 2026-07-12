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

-- Block until the lock is held, use it, release it.
local grant = c:must_lock("orders/checkout", { holder = "worker-a", ttl_ms = 30000 })
-- ... do work guarded by grant.fencing_token ...
grant.release()   -- or: c:lock_release(grant.key, grant.holder, grant.fencing_token)
```

`must_lock`/`lock` and `must_semaphore`/`semaphore` **block**: they poll until the
lock/permit is held or the wait budget elapses (see [Blocking helpers](#blocking-helpers)).
They return a **grant** table `{ key, holder, fencing_token, lease_expires_ms, release() }`.
Every other operation returns the decoded JSON response as a Lua table (or `nil`
for an empty body). Methods are called with `:` so they receive the client as `self`.

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
- `c:try_lock(key, { holder, ttl_ms })` — `wait = false`, single shot; returns the raw response
- `c:must_lock(key, { holder, ttl_ms, max_wait_ms = 30000, retry_interval_ms = 250, max_retries })` / `c:lock(...)` — **blocks** (polls) until held; returns a grant (see [Blocking helpers](#blocking-helpers))
- `c:lock_release(key, holder, fencing_token)` — `key` is accepted for symmetry but not sent

**semaphores**
- `c:semaphore_get(key)`
- `c:semaphore_acquire(key, limit, { holder, ttl_ms, wait = true })`
- `c:try_semaphore(key, limit, { holder, ttl_ms })` — `wait = false`, single shot; returns the raw response
- `c:must_semaphore(key, limit, { holder, ttl_ms, max_wait_ms = 30000, retry_interval_ms = 250, max_retries })` / `c:semaphore(...)` — **blocks** (polls) until held; returns a grant (see [Blocking helpers](#blocking-helpers))
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

- **Redirects are not followed.** luasocket's default redirect-following is
  disabled, so a `3xx` is raised as an error (like any `>= 300`) rather than
  replaying the request — and its `Authorization` / idempotency headers — to the
  `Location` (which could be cross-origin or an `https://`→`http://` downgrade).

### Blocking helpers

`try_lock`/`try_semaphore` set `wait = false` and return the raw acquire response
in one shot (a grant if free right now, otherwise the queued/not-acquired response) —
no polling.

`must_lock`/`lock` and `must_semaphore`/`semaphore` **block until held**. The server
does not hold the connection on `wait = true`; it reserves a FIFO slot and returns
immediately, so these helpers poll:

1. acquire with `wait = true` (using a caller-supplied `holder` or a generated
   `fdc-…` id, and `ttl_ms` defaulting to `60000`);
2. if the acquire already reports `acquired`, return the grant;
3. otherwise poll `lock_get` / `semaphore_get` every `retry_interval_ms` (default
   `250`) until our `holder` appears **with a `fencing_token`**, or `max_wait_ms`
   (default `30000`, or an optional `max_retries`) elapses.

On success they return a grant table `{ key, holder, fencing_token,
lease_expires_ms, release() }` — call `grant.release()` (or pass the fields to
`c:lock_release` / `c:semaphore_release`) when done. On timeout they **raise** (so
wrap blocking calls in `pcall`) a timeout table
`{ status = 0, timeout = true, keys, waited_ms, body }`:

```lua
local ok, res = pcall(function()
  return c:must_lock("orders/checkout", { max_wait_ms = 5000, retry_interval_ms = 200 })
end)
if ok then
  -- res is the held grant
  res.release()
elseif res.timeout then
  print("gave up after " .. res.waited_ms .. "ms")
else
  print("error: HTTP " .. tostring(res.status), res.body)
end
```
- **TLS (fail-closed).** For `https://` URLs the client verifies the server
  certificate by default (`verify = "peer"`) — luasec's insecure `verify = "none"`
  default is **not** used. A CA bundle is auto-detected at request time from, in
  order, `$SSL_CERT_FILE`, `$SSL_CERT_DIR`, then the common OS locations
  (`/etc/ssl/cert.pem`, `/etc/ssl/certs/ca-certificates.crt`,
  `/etc/pki/tls/certs/ca-bundle.crt`, `/etc/ssl/certs`). If verification is on but
  **no CA source is found the request fails** with a clear error rather than
  connecting insecurely.

  Point the client at a specific CA (e.g. for a private CA or when the OS bundle
  isn't in a standard place) via `$SSL_CERT_FILE` or the constructor:

  ```lua
  local c = Fiducia.new("https://api.fiducia.cloud", {
    tls = { cafile = "/path/to/ca.pem" },   -- or capath = "/path/to/certs"
  })
  ```

  Constructor `tls` params always override the defaults and accept any luasec
  parameter (`verify`, `cafile`, `capath`, `protocol`, `options`, …). To opt out
  of verification (insecure — e.g. a self-signed dev server), pass
  `tls = { verify = "none" }`. TLS settings are ignored for `http://` URLs.

## License

Proprietary. See [`../../PROTOCOL.md`](../../PROTOCOL.md) and repository terms.
