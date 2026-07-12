# Fiducia client protocol (HTTP)

> **Machine-readable source of truth:** [`operations.json`](operations.json) — the
> endpoint manifest every client is generated from (run `python3 generate.py`).
> The current endpoint list is in [`ENDPOINTS.md`](ENDPOINTS.md) (also generated).
> This document is the human narrative; if it disagrees with `operations.json`,
> the manifest wins.

The client SDKs are the customer-facing contract; this HTTP shape is
intentionally encapsulated inside them so it can evolve without leaking URL/body
churn into application code. All clients are thin HTTP wrappers over this
contract with language-idiomatic surfaces.

- **Transport:** HTTP only (no TCP). Clients talk to the edge / load balancer,
  which routes each request to the owning shard's leader.
- **Encoding:** JSON request/response bodies; `Content-Type: application/json`.
- **Keys:** lock, semaphore, idempotency, and config keys are slash-safe: reads
  carry them in `?key=...`, and writes carry them in JSON bodies. Resource
  names that remain path segments (`{name}`, `{service}`, `{instanceId}`) are
  URL-encoded.
- **TTLs:** milliseconds (`ttl_ms`).
- **Base URL:** e.g. `https://api.fiducia.cloud` (or a regional LB / local node).

## Endpoints

Legend: **live** = implemented in `fiducia-node` today.

### Locks — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `lockGet(key)` | `GET /v1/locks?key=...` | — | `{key, lock}` |
| `lockAcquire(key, {holder, ttlMs, wait})` | `POST /v1/locks/acquire` | `{key, holder, ttl_ms, wait}` | `{committed, result}` |
| `lockAcquireMany({keys, holder, ttlMs, wait})` | `POST /v1/locks/acquire` | `{keys, holder, ttl_ms, wait}` | `{committed, result}` |
| `lockRelease(key, {holder, fencingToken})` | `POST /v1/locks/release` | `{holder, fencing_token}` | `{committed, result}` |

`wait:false` is try-lock. `wait:true` joins the FIFO wait queue. A successful
single-key or multi-key grant returns one monotonic `fencing_token` in
`result.output`. Multi-key locks are union locks: the grant covers the full
deduped key set, conflicts on any overlapping member key, and releases the whole
union by `{holder, fencing_token}`.

Clients also expose convenience acquire names over the same wire contract,
using each language's casing conventions: `tryLock` / `try_lock` /
`TryLock` force `wait:false`; `mustLock` / `must_lock` / `MustLock` and
`lock` / `Lock` force `wait:true`. Multi-key helpers follow the same pattern
where the client already exposes multi-key locks. Blocking calls can be bounded
with request controls such as lock/request timeout, max retries / retry max,
retry delay, and cancellation/context controls where supported.

**Waiting is client-driven.** The server does **not** hold a request open on
`wait:true` — it reserves the FIFO slot and returns `{acquired:false, queued:true,
position}` immediately. The client then polls `lockGet`/`semaphoreGet` until its
`holder` appears as the current holder (with a `fencing_token`), backing off
between polls, until acquired or its own deadline. The clients expose this as the
high-level **`tryLock` (`wait:false`)** and **`lock`/`mustLock` (`wait:true`,
retries + timeout)** methods (see the README); the retry budget (`ttl`,
`maxWaitTime`, `retryInterval`, `maxRetries`) is entirely client-side. A client
that abandons a wait leaves a queue slot that self-heals once promoted: the grant
then carries a lease TTL and expires if no one holds it.

### Semaphores — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `semaphoreGet(key)` | `GET /v1/semaphores?key=...` | — | `{key, semaphore}` |
| `semaphoreAcquire(key, {holder, ttlMs, max, wait})` | `POST /v1/semaphores/acquire` | `{key, holder, ttl_ms, limit, wait}` | `{committed, result}` |
| `semaphoreRelease(key, {holder, fencingToken})` | `POST /v1/semaphores/release` | `{key, holder, fencing_token}` | `{committed, result}` |

Semaphores are counting leases: up to `limit` holders can hold the key at once,
and each holder gets a distinct fencing token.
Clients mirror the lock helpers with `trySemaphore` / `try_semaphore` /
`TrySemaphore` for `wait:false` and `mustSemaphore` / `must_semaphore` /
`MustSemaphore` plus `semaphore` / `Semaphore` for `wait:true`, with the same
request timeout, retry, delay, and cancellation controls.

### Idempotency keys — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `idempotencyGet(key)` | `GET /v1/idempotency?key=...` | — | `{key, found, record}` |
| `idempotencyClaim(key, {owner, ttlMs, ttl, metadata})` | `POST /v1/idempotency/claim` | `{key, owner, ttl_ms, ttl, metadata}` | `{committed, result}` |
| `idempotencyComplete(key, {owner, fencingToken, result})` | `POST /v1/idempotency/complete` | `{key, owner, fencing_token, result}` | `{committed, result}` |

`claim` is the retry-safe first-writer operation. The first active claim stores
`owner`, metadata, a fencing token, and the TTL window; duplicate claims for the
same key return the existing active record instead of creating another run.
`complete` is guarded by the original owner and fencing token and can attach the
durable result clients should replay for later duplicates. `ttl_ms` is numeric
milliseconds; `ttl` also accepts friendly strings such as `60s`, `5m`, `24h`,
and `7d`.

End-customer API retries can use the HTTP header `Idempotency-Key` on any
mutating request (`POST`, `PUT`, `PATCH`, `DELETE`) instead of manually calling
the claim/complete endpoints. The edge preserves the header, and the regional
load balancer consumes it before the node hop. Keys are scoped to the
authenticated org, hashed before storage, retained for 24 hours, and bound to a
request fingerprint made from method, path/query, content type, and body. Exact
retries replay the original status/body and include `Idempotent-Replayed: true`.
The same key with a different request returns `409 idempotency_key_conflict`; a
retry while the original request is still running returns
`409 idempotency_key_in_progress` with `Retry-After: 1`.

SDKs expose this as a request-control option where supported:
TypeScript `idempotencyKey`, Python `idempotency_key` (also accepts
`idempotencyKey`), Go `IdempotencyKey` on option structs, and Rust
`RequestControl { idempotency_key: Some(...) }`.

### Reader-writer locks — client extension

The client SDKs reserve these names for reader-writer lock APIs; the current
node runtime does not expose them yet.

| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `rwAcquireRead(key, {ttlMs, wait})` | `POST /v1/rw/{key}/read` | `{ttl_ms, wait}` | `{acquired, fencing_token, lock_id}` |
| `rwEndRead(key, lockId)` | `POST /v1/rw/{key}/read/end` | `{lock_id}` | `{released}` |
| `rwAcquireWrite(key, {ttlMs, wait})` | `POST /v1/rw/{key}/write` | `{ttl_ms, wait}` | `{acquired, fencing_token, lock_id}` |
| `rwEndWrite(key, lockId)` | `POST /v1/rw/{key}/write/end` | `{lock_id}` | `{released}` |

### Config KV — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `kvGet(key)` | `GET /v1/kv?key=...` | — | `{key, found, entry}` |
| `kvPut(key, value, {ttlMs, prevRevision})` | `PUT /v1/kv?key=...` | `{value, ttl_ms, prev_revision}` | `{committed, result}` |
| `kvDelete(key)` | `DELETE /v1/kv?key=...` | — | `{committed, result}` |
| `kvList(prefix)` | `GET /v1/kv?prefix=...` | — | `{prefix, entries}` |
| `kvWatch(key)` | `GET /v1/kv?key=...&watch=true` | — | SSE stream |
| `kvWatchPrefix(prefix)` | `GET /v1/kv?prefix=...&watch=true` | — | SSE stream |

### Rate limiting — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `rateLimitCheck(tenant, key, {algorithm, limit, windowMs, refillPerSecond, cost})` | `POST /v1/rate-limit/{tenant}/{key}/check` | `{algorithm, limit, window_ms, refill_per_second, cost}` | `{committed, result}` |
| `rateLimitGet(tenant, key)` | `GET /v1/rate-limit/{tenant}/{key}` | — | `{found, limit}` |

`algorithm` is `token_bucket` or `sliding_window`.

### Cron & scheduling — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `scheduleUpsert(name, {cron, oneShotAtMs, target, delivery, maxRetries})` | `PUT /v1/cron/schedules/{name}` | `{cron, one_shot_at_ms, target, delivery, max_retries}` | `{committed, result}` |
| `scheduleGet(name)` | `GET /v1/cron/schedules/{name}` | — | `{found, schedule}` |
| `scheduleRecordRun(name, {fireId, firedAtMs})` | `POST /v1/cron/schedules/{name}/runs` | `{fire_id, fired_at_ms}` | `{committed, result}` |
| `scheduleHistory(name)` | `GET /v1/cron/schedules/{name}/history` | — | `{name, history}` |

Exactly one of `cron` or `one_shot_at_ms` is required. `target.kind` is
`webhook`, `queue`, or `grpc`.

### Leader election — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `electionCampaign(name, candidate, ttlMs, metadata?)` | `POST /v1/elections/{name}/campaign` | `{candidate, ttl_ms, metadata}` | `{committed, result}` |
| `electionRenew(name, candidate, fencingToken)` | `POST /v1/elections/{name}/renew` | `{candidate, fencing_token}` | `{committed, result}` |
| `electionResign(name, candidate, fencingToken)` | `POST /v1/elections/{name}/resign` | `{candidate, fencing_token}` | `{committed, result}` |
| `electionGet(name)` | `GET /v1/elections/{name}` | — | `{name, held, leadership}` |
| `electionWatch(name)` | `GET /v1/elections/{name}/watch` | — | SSE stream |

Campaign metadata is copied onto the returned `leadership` object. Use it for
customer-facing routing facts such as `address`, `region`, `version`,
`service`, or `instance_id`; watchers then receive the current leader plus the
same metadata after failover.

### Service discovery — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `serviceRegister(service, instanceId, address, ttlMs, metadata)` | `PUT /v1/services/{service}/instances/{id}` | `{address, ttl_ms, metadata}` | `{committed, result}` |
| `serviceHeartbeat(service, instanceId, ttlMs?)` | `POST /v1/services/{service}/instances/{id}/heartbeat` | `{ttl_ms}` | `{committed, result}` |
| `serviceDeregister(service, instanceId)` | `DELETE /v1/services/{service}/instances/{id}` | — | `{committed, result}` |
| `serviceInstances(service, metadata?)` | `GET /v1/services/{service}?metadata.KEY=VALUE` | — | `{service, instances}` |
| `serviceList()` | `GET /v1/services` | — | `{services}` |
| `serviceWatch(service)` | `GET /v1/services/{service}/watch` | — | SSE stream |

`serviceInstances` accepts optional exact-match metadata filters. Multiple
filters are ANDed by the node, for example `metadata.region=us-east` plus
`metadata.version=blue` returns only live instances matching both values.
For primary routing, register each instance with metadata like
`role=invoice-reconciler`, `leader=true`, `term=42`, or `fencing_token=918273`
after it wins/renews an election, then query
`serviceInstances("invoice-reconciler", {leader: "true"})` or watch both the
service and election streams.

### Misc — live
| Method | Endpoint | Returns |
|--------|----------|---------|
| `health()` | `GET /healthz` | `{status, service}` |
| `status()` | `GET /v1/status` | `{service, consensus, ...}` |

## Fencing tokens

Successful lock / RW / election grants return a monotonic `fencing_token`. Pass
it to the resource you're protecting and have that resource reject any token
lower than the highest it has seen — this defeats a stale holder that paused past
its lease (Kleppmann fencing).

`fencing_token` (and KV `revision`) are `u64` counters incremented by one per
grant. They are transported as JSON numbers, so JS/WebAssembly clients handle
them as `number`: exact for any realistic deployment lifetime — reaching
`Number.MAX_SAFE_INTEGER` (2^53−1 ≈ 9.0e15) would take ~9 quadrillion grants
(~centuries at 10^6/s). Clients treat them as opaque monotonic values; do not do
arithmetic on them beyond compare. The WebAssembly client additionally rejects a
supplied token/count that isn't a safe integer, so a caller bug fails loudly
rather than silently rounding.

## Errors

Non-2xx responses carry a JSON body where possible. Clients surface the status
code and parsed body; they do not retry by default (the edge/LB already handles
leader redirects).
