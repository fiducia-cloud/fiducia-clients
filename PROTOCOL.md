# Fiducia client protocol (HTTP)

The single source of truth every client in [`clients/`](clients/) targets. All
clients are thin HTTP wrappers over this contract — same methods, same
endpoints, language-idiomatic surface.

- **Transport:** HTTP only (no TCP). Clients talk to the edge / load balancer,
  which routes each request to the owning shard's leader.
- **Encoding:** JSON request/response bodies; `Content-Type: application/json`.
- **Keys:** the `{key}` / `{name}` / `{service}` path segment is URL-encoded.
- **TTLs:** milliseconds (`ttl_ms`).
- **Base URL:** e.g. `https://api.fiducia.cloud` (or a regional LB / local node).

## Endpoints

Legend: **live** = implemented in `fiducia-node` today · **planned** = part of the
contract, server implementation in progress (clients ship ready for it).

### Locks — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `lockGet(key)` | `GET /v1/locks/{key}` | — | `{key, lock}` |
| `lockAcquire(key, {holder, ttlMs, wait})` | `POST /v1/locks/{key}/acquire` | `{holder, ttl_ms, wait}` | `{committed, result}` |
| `lockAcquireBody({key, holder, ttlMs, wait, max})` | `POST /v1/locks/acquire` | `{key, holder, ttl_ms, wait, max}` | `{committed, result}` |
| `lockAcquireMany({keys, holder, ttlMs, wait})` | `POST /v1/locks/acquire-many` | `{keys, holder, ttl_ms, wait}` | `{committed, result}` |
| `lockReleaseMany(lockId)` | `POST /v1/locks/release-many` | `{lock_id}` | `{committed, result}` |
| `lockRelease(key, {holder, fencingToken})` | `POST /v1/locks/{key}/release` | `{holder, fencing_token}` | `{committed, result}` |
| `lockWatch(key)` | `GET /v1/locks/{key}/watch` | — | SSE stream (**planned**) |

`wait:false` is try-lock. `wait:true` joins the FIFO wait queue. A successful
single-key grant returns a monotonic `fencing_token` in `result`. A successful
multi-key grant returns one `lock_id` plus `fencing_tokens` keyed by member key.
The server sorts/dedupes `keys`, caps composites at five keys, and conflicts on
any overlapping member key. Composite locks are exclusive: they block mutexes
and semaphores on every member key until released by `lock_id`.

### Semaphores — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `semaphoreAcquire(key, {holder, ttlMs, max, wait})` | `POST /v1/semaphores/{key}/acquire` | `{holder, ttl_ms, max, wait}` | `{committed, result}` |
| `semaphoreRelease(key, {holder, fencingToken})` | `POST /v1/semaphores/{key}/release` | `{holder, fencing_token}` | `{committed, result}` |

Semaphores are the same lock state machine with `max > 1`: up to `max` holders
can hold the key at once, and each holder gets a distinct fencing token.

### Reader-writer locks — planned
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `rwAcquireRead(key, {ttlMs, wait})` | `POST /v1/rw/{key}/read` | `{ttl_ms, wait}` | `{acquired, fencing_token, lock_id}` |
| `rwEndRead(key, lockId)` | `POST /v1/rw/{key}/read/end` | `{lock_id}` | `{released}` |
| `rwAcquireWrite(key, {ttlMs, wait})` | `POST /v1/rw/{key}/write` | `{ttl_ms, wait}` | `{acquired, fencing_token, lock_id}` |
| `rwEndWrite(key, lockId)` | `POST /v1/rw/{key}/write/end` | `{lock_id}` | `{released}` |

### Config KV — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `kvGet(key)` | `GET /v1/kv/{key}` | — | `{key, found, entry}` |
| `kvPut(key, value, {ttlMs, prevRevision})` | `PUT /v1/kv/{key}` | `{value, ttl_ms, prev_revision}` | `{committed, result}` |
| `kvDelete(key)` | `DELETE /v1/kv/{key}` | — | `{committed, result}` |
| `kvList(prefix)` | `GET /v1/kv?prefix=...` | — | `{keys}` (**planned**) |
| `kvWatch(key, {startRevision})` | `GET /v1/kv/{key}/watch` | — | SSE stream (**planned**) |

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
| `electionCampaign(name, candidate, ttlMs)` | `POST /v1/elections/{name}/campaign` | `{candidate, ttl_ms}` | `{committed, result}` |
| `electionRenew(name, candidate, fencingToken)` | `POST /v1/elections/{name}/renew` | `{candidate, fencing_token}` | `{committed, result}` |
| `electionResign(name, candidate, fencingToken)` | `POST /v1/elections/{name}/resign` | `{candidate, fencing_token}` | `{committed, result}` |
| `electionGet(name)` | `GET /v1/elections/{name}` | — | `{name, held, leadership}` |

### Service discovery — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `serviceRegister(service, instanceId, address, ttlMs)` | `PUT /v1/services/{service}/instances/{id}` | `{address, ttl_ms}` | `{committed, result}` |
| `serviceHeartbeat(service, instanceId)` | `POST /v1/services/{service}/instances/{id}/heartbeat` | — | `{committed, result}` |
| `serviceDeregister(service, instanceId)` | `DELETE /v1/services/{service}/instances/{id}` | — | `{committed, result}` |
| `serviceInstances(service)` | `GET /v1/services/{service}` | — | `{service, instances}` |
| `serviceList()` | `GET /v1/services` | — | `{services}` |

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

## Errors

Non-2xx responses carry a JSON body where possible. Clients surface the status
code and parsed body; they do not retry by default (the edge/LB already handles
leader redirects).
