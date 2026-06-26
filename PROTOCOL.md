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

### Locks & semaphores — planned
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `lockAcquire(key, {ttlMs, wait, max})` | `POST /v1/locks/{key}/acquire` | `{ttl_ms, wait, max}` | `{acquired, fencing_token, lock_id, holders, max}` |
| `lockRelease(key, lockId)` | `POST /v1/locks/{key}/release` | `{lock_id}` | `{released}` |

`max` defaults to 1 (mutex); `max > 1` is a counting semaphore. `wait` (default
true) blocks via long-poll until granted; `wait:false` is try-lock.

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
| `kvPut(key, value, {ttlMs})` | `PUT /v1/kv/{key}` | `{value, ttl_ms}` | `{committed, result}` |
| `kvDelete(key)` | `DELETE /v1/kv/{key}` | — | `{committed, result}` |
| `kvList(prefix)` | `GET /v1/kv?prefix=...` | — | `{keys}` |

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
