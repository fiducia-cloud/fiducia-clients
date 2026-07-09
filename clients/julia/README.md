# Fiducia

Fiducia HTTP client for Julia. A thin wrapper over the fiducia.cloud HTTP
contract (`PROTOCOL.md`), built on [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl)
and [JSON.jl](https://github.com/JuliaIO/JSON.jl).

## Install

Once registered in the Julia General registry:

```julia
using Pkg
Pkg.add("Fiducia")
```

Or from a checkout of this repo:

```julia
using Pkg
Pkg.develop(path = "clients/julia")
```

## Usage

```julia
using Fiducia

c = Client("https://api.fiducia.cloud")

# Block until the lock is actually HELD (polls; generates a holder), then release.
held = must_lock(c, "orders/checkout"; ttl_ms = 30000, max_wait_ms = 5000)
lock_release(c, "orders/checkout", held["holder"], held["fencing_token"])

# Low-level, single request: returns the raw response (may be a queued ticket).
grant = lock_acquire(c, "orders/checkout"; ttl_ms = 30000)
out = grant["result"]["output"]

# Config KV with a compare-and-swap guard.
kv_put(c, "flags/rollout", "on"; ttl_ms = 60000, prev_revision = 0)
kv_get(c, "flags/rollout")
```

Every operation takes the `Client` as its first argument and returns the parsed
JSON response (a `Dict`, `Vector`, scalar, or `nothing` for an empty body).
Optional keyword arguments (`holder`, `ttl_ms`, `metadata`, …) are only sent
when provided, which preserves compare-and-swap semantics.

Each request carries a 30-second connect/read timeout by default; pass
`Client(url; connect_timeout = 10, read_timeout = 10)` to change it (or `0` to
disable). Requests are issued exactly once — they never auto-follow redirects and
are never auto-retried — so a mutating call is never silently duplicated and a
3xx from the edge surfaces as a `FiduciaError`.

`lock(c, key; ...)` is the blocking alias of `must_lock`; because Julia already
exports `lock`, it is added as a method on `Base.lock` and is callable as
`lock(c, key)` without importing anything extra.

## Errors

Any response with HTTP status >= 300 throws a `FiduciaError`:

```julia
try
    lock_release(c, "orders/checkout", "worker-a", 999)
catch err
    err isa FiduciaError && @warn "fiducia failed" err.status err.body
end
```

## Method surface

- misc: `health`, `status`
- locks: `lock_get`, `lock_acquire`, `lock_acquire_many`, `try_lock`,
  `must_lock`, `lock` (`Base.lock`), `lock_release`
- semaphores: `semaphore_get`, `semaphore_acquire`, `try_semaphore`,
  `must_semaphore`, `semaphore`, `semaphore_release`
- idempotency: `idempotency_get`, `idempotency_claim`, `idempotency_complete`
- reader-writer locks: `rw_acquire_read`, `rw_end_read`, `rw_acquire_write`,
  `rw_end_write`
- config KV: `kv_get`, `kv_put`, `kv_delete`, `kv_list`
- rate limiting: `rate_limit_get`, `rate_limit_check`
- cron & scheduling: `schedule_get`, `schedule_upsert`, `schedule_record_run`,
  `schedule_history`
- leader election: `election_get`, `election_campaign`, `election_renew`,
  `election_resign`
- service discovery: `service_instances`, `service_register`,
  `service_heartbeat`, `service_deregister`, `service_list`

## Publishing

This package is published to the **Julia General registry** via the
[JuliaRegistrator](https://github.com/JuliaRegistries/Registrator.jl) GitHub App.
The release automation tags `clients/julia/v${PACKAGE_VERSION}` and creates a
`gh release`; registration is then triggered by commenting `@JuliaRegistrator`
on the release commit. JuliaRegistrator opens a pull request against the General
registry, and TagBot keeps subsequent releases in sync.

`./publish.sh` delegates to the repo-wide `scripts/publish-client.sh julia`.

## License

UNLICENSED / proprietary. See `LICENSE.txt`.
