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

### Counters — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `counterGet(key)` | `GET /v1/counters?key=...` | — | `{key, found, counter}` |
| `counterAdd(key, {delta, prevRevision})` | `POST /v1/counters/add` | `{key, delta, prev_revision}` | `{committed, result}` |
| `counterSet(key, {value, prevRevision})` | `POST /v1/counters/set` | `{key, value, prev_revision}` | `{committed, result}` |

A counter is a replicated signed 64-bit integer per key with a monotonic
`mod_revision`. `add` moves it by a (possibly negative) `delta`, creating it at 0
first; `set` writes an absolute value (e.g. reset to 0). Both accept an optional
`prev_revision` that makes the mutation a **compare-and-set** — it applies only if
the counter's current `mod_revision` matches, else `result.output` is
`{ ok: false, reason: "cas_mismatch", current_revision }`. A grant returns the new
`{ value, mod_revision }` in `result.output`. An absent counter reads as
`found: false` and is treated as 0. Keys are slash-safe (`?key=` on reads, JSON
body on writes). Use counters for success/failure thresholds, quota tallies, and
barrier fan-in counts.

### Barriers — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `barrierGet(name)` | `GET /v1/barriers?name=...` | — | `{name, found, barrier}` |
| `barrierCreate(name, {policy, expected, deadlineMs})` | `POST /v1/barriers/create` | `{name, policy, expected, deadline_ms}` | `{committed, result}` |
| `barrierArrive(name, {participant, weight, veto})` | `POST /v1/barriers/arrive` | `{name, participant, weight, veto}` | `{committed, result}` |

A barrier gathers arrivals from named participants and resolves per its
`policy.kind`: `all` (every `expected` participant), `quorum` (`required`
distinct arrivals), `first_success` (first non-veto arrival), `any_veto` (all
arrive but any veto aborts), `best_by_deadline` (whoever arrived by
`deadline_ms`), or `weighted_quorum` (arrival `weight`s sum to
`required_weight`). Repeat arrivals by the same participant are idempotent, and a
bare `arrive` on an unknown barrier auto-creates a single-participant `all`
barrier. `result.output.barrier.status` is `pending`, `satisfied`, `vetoed`, or
`timed_out`; `result.output.resolved` is a convenience boolean on arrive. Names
are slash-safe. Use barriers for research-swarm fan-in, evaluator panels,
multi-model verification, and rollout stage gates.

### Tasks — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `taskGet(name)` | `GET /v1/tasks?name=...` | — | `{name, found, task}` |
| `taskCreate(name, {taskType, payload, deadlineMs})` | `POST /v1/tasks/create` | `{name, task_type, payload, deadline_ms}` | `{committed, result}` |
| `taskClaim(name, {worker, ttlMs})` | `POST /v1/tasks/claim` | `{name, worker, ttl_ms}` | `{committed, result}` |
| `taskProgress(name, {worker, fencingToken, percent, checkpoint})` | `POST /v1/tasks/progress` | `{name, worker, fencing_token, percent, checkpoint}` | `{committed, result}` |
| `taskComplete(name, {worker, fencingToken, result})` | `POST /v1/tasks/complete` | `{name, worker, fencing_token, result}` | `{committed, result}` |
| `taskFail(name, {worker, fencingToken, retryable})` | `POST /v1/tasks/fail` | `{name, worker, fencing_token, retryable}` | `{committed, result}` |
| `taskCancel(name)` | `POST /v1/tasks/cancel` | `{name}` | `{committed, result}` |

A durable task is a claimable unit of work. `create` is idempotent. `claim`
grants a fresh **fencing token** and an ownership lease when the task is pending
or its prior lease expired — an actively owned task is not re-granted
(`result.output` is `{ ok: false, reason: "already_claimed", owner }`).
`progress`/`complete`/`fail` require the current owner + fencing token, so a stale
worker that lost the claim is rejected (`{ ok: false, reason: "fenced" }`).
A retryable `fail` returns the task to `pending` for reassignment; otherwise it
ends `failed`. `cancel` is terminal. `result.output.task.status` is `pending`,
`claimed`, `running`, `completed`, `failed`, or `cancelled`. Names are slash-safe.
This is the coordination backbone under agent work-items: the node owns *who may
act*; the application database owns the rich task detail (keep `payload` small).

### Effects (approval escrow) — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `effectGet(name)` | `GET /v1/effects?name=...` | — | `{name, found, effect}` |
| `effectPrepare(name, {effectType, payload, risk, idempotencyKey, requiredApprovals})` | `POST /v1/effects/prepare` | `{name, effect_type, payload, risk, idempotency_key, required_approvals}` | `{committed, result}` |
| `effectApprove(name, {principal})` | `POST /v1/effects/approve` | `{name, principal}` | `{committed, result}` |
| `effectCommit(name, {result})` | `POST /v1/effects/commit` | `{name, result}` | `{committed, result}` |
| `effectAbort(name)` | `POST /v1/effects/abort` | `{name}` | `{committed, result}` |

Separate *preparing* a dangerous action from *authorizing* and *executing* it.
`prepare` is idempotent (`required_approvals: 0` is pre-approved). `approve`
records distinct principals (duplicates count once); reaching `required_approvals`
moves the effect to `approved`. `commit` executes exactly once — a repeat commit
replays the recorded result (`result.output.committed` is `true` the first time,
`false` on replay) and never re-runs; committing an unapproved effect returns
`{ ok: false, reason: "not_approved" }`. `abort` is terminal. The
`idempotency_key` binds the effect to the external operation so the executor
stays effectively-once even under redelivery. Use for payments, deploys,
deletes, public posts, and sensitive-data access.

### Handoffs — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `handoffGet(name)` | `GET /v1/handoffs?name=...` | — | `{name, found, handoff}` |
| `handoffOffer(name, {resource, from, to, fromToken, context, ttlMs})` | `POST /v1/handoffs/offer` | `{name, resource, from, to, from_token, context, ttl_ms}` | `{committed, result}` |
| `handoffAccept(name, {to})` | `POST /v1/handoffs/accept` | `{name, to}` | `{committed, result}` |
| `handoffReject(name, {to})` | `POST /v1/handoffs/reject` | `{name, to}` | `{committed, result}` |

Transfer responsibility for a resource from one holder to another with no moment
of dual or zero ownership. `from` (presenting its current `from_token`) offers
the `resource` to `to`; while `offered`, `from` keeps authority. On `accept`, the
node mints a strictly higher `to_token` for the new owner (`result.output.to_token`),
so the guarded resource's fencing rejects the old owner — an atomic transfer.
Only the offered recipient may accept/reject (`{ ok: false, reason:
"not_recipient" }` otherwise). `reject` or a passed `ttl_ms` deadline leaves
ownership with `from` (`status` `rejected`/`expired`). Use for triage→specialist
delegation and research→legal ticket transfer across agent runtimes.

### Decisions — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `decisionGet(name)` | `GET /v1/decisions?name=...` | — | `{name, found, decision}` |
| `decisionPropose(name, {question, options, policy, deadlineMs})` | `POST /v1/decisions/propose` | `{name, question, options, policy, deadline_ms}` | `{committed, result}` |
| `decisionVote(name, {voter, option, confidence, weight, veto, evidence})` | `POST /v1/decisions/vote` | `{name, voter, option, confidence, weight, veto, evidence}` | `{committed, result}` |

A decision is richer than a raw vote: it declares typed `options` and a
resolution `policy.kind` — `plurality` (most total weight once `min_votes` cast),
`threshold` (first option to reach `required_weight`), or `unanimous`. Each vote
carries a chosen `option` (omit to abstain), a `confidence`, a `weight`
(specialists count more), an optional `veto`, and `evidence` references.
Re-voting **replaces** a voter's prior vote; a vote for an option outside the
declared set is rejected. A veto aborts (`status: vetoed`); ties break to the
lexicographically smallest option; a passed `deadline_ms` forces a plurality
outcome (`timed_out` if there's nothing to decide). `result.output.decision`
carries `status` (`open`/`resolved`/`vetoed`/`timed_out`), `winner`, and per-option
`tallies`. Don't let agents vote from copied conclusions — record independent
`evidence`. Use for deployment-safety votes, evaluator panels, and debate systems.

### Budgets — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `budgetGet(name)` | `GET /v1/budgets?name=...` | — | `{name, found, budget}` |
| `budgetSet(name, {limit})` | `POST /v1/budgets/set` | `{name, limit}` | `{committed, result}` |
| `budgetReserve(name, {reservationId, holder, amount})` | `POST /v1/budgets/reserve` | `{name, reservation_id, holder, amount}` | `{committed, result}` |
| `budgetCommit(name, {reservationId, actual})` | `POST /v1/budgets/commit` | `{name, reservation_id, actual}` | `{committed, result}` |
| `budgetRelease(name, {reservationId})` | `POST /v1/budgets/release` | `{name, reservation_id}` | `{committed, result}` |

A budget has a per-axis ceiling (`usd_micros`, `tokens`, `tool_calls`; an unset
axis is unlimited). A worker `reserve`s an amount **before** spending — the
reservation is rejected (`{ ok: false, reason: "insufficient_budget", available }`)
if it would exceed any limited axis, so ten agents cannot each independently
believe they can spend the same remaining dollar. `commit` records the `actual`
spend (capped at the reservation) and **frees the difference**; `release` returns
a still-held reservation's full headroom. `result.output.budget` reports `limit`,
`reserved`, `spent`, `available`, and per-reservation status
(`held`/`committed`/`released`). Nest budgets by naming them by scope
(`org/acme`, `org/acme/workflow/42`). Use to bound swarm spend across
organization → customer → workflow → agent → tool-call.

### Claims — live
| Method | Endpoint | Body | Returns |
|--------|----------|------|---------|
| `claimGet(name)` | `GET /v1/claims?name=...` | — | `{name, found, claim}` |
| `claimAssert(name, {subject, predicate, value, confidence, author, evidence, validUntilMs})` | `POST /v1/claims/assert` | `{name, subject, predicate, value, confidence, author, evidence, valid_until_ms}` | `{committed, result}` |
| `claimSupport(name, {agent})` | `POST /v1/claims/support` | `{name, agent}` | `{committed, result}` |
| `claimContest(name, {agent, reason})` | `POST /v1/claims/contest` | `{name, agent, reason}` | `{committed, result}` |
| `claimResolve(name, {accepted})` | `POST /v1/claims/resolve` | `{name, accepted}` | `{committed, result}` |
| `claimSupersede(name, {supersededBy})` | `POST /v1/claims/supersede` | `{name, superseded_by}` | `{committed, result}` |

A claim is a versioned `subject`/`predicate`/`value` an agent believes, with a
`confidence` and `evidence`. Others `support` or `contest` it (a contest moves it
to `contested`); an authorized process `resolve`s it (`accepted`/`rejected`,
terminal), or a newer claim `supersede`s it. Re-`assert`ing a new value **bumps
the version** and resets support/contests. `result.output.claim` carries
`status` (`asserted`/`contested`/`accepted`/`rejected`/`superseded`),
`supporters`, `contests`, and `version`. This is a blackboard of immutable,
versioned beliefs — the coordination-grade counterpart to dumping every agent's
prose into a shared vector store. The rule: semantic similarity may *surface* a
claim, but only an authorized resolution makes it authoritative. Use for shared
agent memory where two agents disagree about a fact.

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
