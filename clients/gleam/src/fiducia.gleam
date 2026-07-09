//// Fiducia HTTP client (Gleam). Transport: gleam_httpc; JSON: gleam_json; plus
//// gleam_stdlib. Implements PROTOCOL.md.
////
////   import fiducia
////   import gleam/option.{None, Some}
////   let c = fiducia.new("https://api.fiducia.cloud")
////   let assert Ok(lock) =
////     fiducia.lock_acquire(c, "orders/checkout", None, Some(30_000), True)
////   // `lock` is a Dynamic: pull result.output.fencing_token with a
////   // gleam/dynamic/decode decoder, then:
////   //   fiducia.lock_release(c, "orders/checkout", "worker-a", token)

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http.{type Method, Delete, Get, Post, Put}
import gleam/http/request
import gleam/httpc
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// A failed call: a non-2xx HTTP response (`Http`, carrying the numeric status
/// and the parsed JSON body as a `Dynamic`), a transport/network failure
/// (`Transport`), or a blocking acquire that never became held within its wait
/// budget (`Timeout`, carrying the elapsed budget in milliseconds).
pub type FiduciaError {
  Http(status: Int, body: Dynamic)
  Transport(message: String)
  Timeout(waited_ms: Int)
}

/// A held lock or semaphore grant returned by the blocking `must_*` / `lock` /
/// `semaphore` helpers. It proves you hold `key` as `holder`; pass `holder` and
/// `fencing_token` to the matching `*_release` to give it back.
pub type Grant {
  Grant(
    key: String,
    holder: String,
    fencing_token: Int,
    lease_expires_ms: Option(Int),
  )
}

/// Retry budget for the blocking `must_*` / `lock` / `semaphore` helpers:
/// `max_wait_ms` is the total time to keep polling, `retry_interval_ms` the gap
/// between polls, and `max_retries` an optional hard cap on poll attempts.
pub type Retry {
  Retry(max_wait_ms: Int, retry_interval_ms: Int, max_retries: Option(Int))
}

/// Default retry budget, matching the reference clients: wait up to 30s, poll
/// every 250ms, with no fixed attempt cap.
pub fn default_retry() -> Retry {
  Retry(max_wait_ms: 30_000, retry_interval_ms: 250, max_retries: None)
}

/// An opaque handle to a Fiducia endpoint. Build it with `new`.
pub opaque type Client {
  Client(base: String)
}

/// Create a client for `base_url`. Trailing slashes are trimmed so paths join
/// cleanly. Every method returns `Result(Dynamic, FiduciaError)`; decode the
/// `Dynamic` with `gleam/dynamic/decode` when you need typed fields.
pub fn new(base_url: String) -> Client {
  Client(base: drop_trailing_slashes(base_url))
}

// --- misc ---

/// `GET /healthz` — liveness probe.
pub fn health(client: Client) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/healthz", None)
}

/// `GET /v1/status` — per-shard consensus status.
pub fn status(client: Client) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/status", None)
}

// --- locks ---

/// `GET /v1/locks?key=…` — inspect a lock member key.
pub fn lock_get(client: Client, key: String) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/locks?key=" <> enc(key), None)
}

/// `POST /v1/locks/acquire` — acquire a single-key lock (try-lock unless `wait`).
pub fn lock_acquire(
  client: Client,
  key: String,
  holder: Option(String),
  ttl_ms: Option(Int),
  wait: Bool,
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [#("key", json.string(key))],
        opt_string("holder", holder),
        opt_int("ttl_ms", ttl_ms),
        [#("wait", json.bool(wait))],
      ]),
    )
  send(client, Post, "/v1/locks/acquire", Some(body))
}

/// `POST /v1/locks/acquire` — multi-key UNION lock (all-or-nothing across `keys`).
pub fn lock_acquire_many(
  client: Client,
  keys: List(String),
  holder: Option(String),
  ttl_ms: Option(Int),
  wait: Bool,
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [#("keys", json.array(keys, json.string))],
        opt_string("holder", holder),
        opt_int("ttl_ms", ttl_ms),
        [#("wait", json.bool(wait))],
      ]),
    )
  send(client, Post, "/v1/locks/acquire", Some(body))
}

/// `lock_acquire` with `wait=false`: take the lock now or fail fast.
pub fn try_lock(
  client: Client,
  key: String,
  holder: Option(String),
  ttl_ms: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  lock_acquire(client, key, holder, ttl_ms, False)
}

/// Blocking acquire: acquire `key` now, or reserve a FIFO slot and POLL
/// `lock_get` until we hold it or the `retry` budget elapses. Unlike the raw
/// `lock_acquire(wait=true)` (which returns immediately with a queued ticket),
/// this returns a held `Grant` or `Error(Timeout(..))`. `holder` defaults to a
/// generated id and `ttl_ms` to 60s when `None`; use `default_retry()` for the
/// standard 30s/250ms budget.
pub fn must_lock(
  client: Client,
  key: String,
  holder: Option(String),
  ttl_ms: Option(Int),
  retry: Retry,
) -> Result(Grant, FiduciaError) {
  let hold = resolve_holder(holder)
  let ttl = Some(option.unwrap(ttl_ms, 60_000))
  use resp <- result.try(lock_acquire(client, key, Some(hold), ttl, True))
  case output_grant(resp, key, hold) {
    Some(grant) -> Ok(grant)
    None -> poll_lock(client, key, hold, now_ms() + retry.max_wait_ms, retry, 0)
  }
}

/// Alias of `must_lock`.
pub fn lock(
  client: Client,
  key: String,
  holder: Option(String),
  ttl_ms: Option(Int),
  retry: Retry,
) -> Result(Grant, FiduciaError) {
  must_lock(client, key, holder, ttl_ms, retry)
}

/// `POST /v1/locks/release` — release the whole grant by its fencing token.
/// `key` is accepted for call-site symmetry but is not sent in the body.
pub fn lock_release(
  client: Client,
  key: String,
  holder: String,
  fencing_token: Int,
) -> Result(Dynamic, FiduciaError) {
  let _ = key
  let body =
    json.object([
      #("holder", json.string(holder)),
      #("fencing_token", json.int(fencing_token)),
    ])
  send(client, Post, "/v1/locks/release", Some(body))
}

// --- semaphores ---

/// `GET /v1/semaphores?key=…` — inspect a semaphore.
pub fn semaphore_get(
  client: Client,
  key: String,
) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/semaphores?key=" <> enc(key), None)
}

/// `POST /v1/semaphores/acquire` — take a permit (try unless `wait`).
pub fn semaphore_acquire(
  client: Client,
  key: String,
  limit: Int,
  holder: Option(String),
  ttl_ms: Option(Int),
  wait: Bool,
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [#("key", json.string(key))],
        opt_string("holder", holder),
        opt_int("ttl_ms", ttl_ms),
        [#("limit", json.int(limit)), #("wait", json.bool(wait))],
      ]),
    )
  send(client, Post, "/v1/semaphores/acquire", Some(body))
}

/// `semaphore_acquire` with `wait=false`.
pub fn try_semaphore(
  client: Client,
  key: String,
  limit: Int,
  holder: Option(String),
  ttl_ms: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  semaphore_acquire(client, key, limit, holder, ttl_ms, False)
}

/// Blocking acquire: take a permit now, or POLL `semaphore_get` until we hold
/// one or the `retry` budget elapses. Returns a held `Grant` or
/// `Error(Timeout(..))` (contrast the raw `semaphore_acquire(wait=true)`, which
/// returns a queued ticket immediately). `holder` defaults to a generated id and
/// `ttl_ms` to 60s when `None`.
pub fn must_semaphore(
  client: Client,
  key: String,
  limit: Int,
  holder: Option(String),
  ttl_ms: Option(Int),
  retry: Retry,
) -> Result(Grant, FiduciaError) {
  let hold = resolve_holder(holder)
  let ttl = Some(option.unwrap(ttl_ms, 60_000))
  use resp <- result.try(semaphore_acquire(
    client,
    key,
    limit,
    Some(hold),
    ttl,
    True,
  ))
  case output_grant(resp, key, hold) {
    Some(grant) -> Ok(grant)
    None ->
      poll_semaphore(client, key, hold, now_ms() + retry.max_wait_ms, retry, 0)
  }
}

/// Alias of `must_semaphore`.
pub fn semaphore(
  client: Client,
  key: String,
  limit: Int,
  holder: Option(String),
  ttl_ms: Option(Int),
  retry: Retry,
) -> Result(Grant, FiduciaError) {
  must_semaphore(client, key, limit, holder, ttl_ms, retry)
}

/// `POST /v1/semaphores/release` — return one permit.
pub fn semaphore_release(
  client: Client,
  key: String,
  holder: String,
  fencing_token: Int,
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object([
      #("key", json.string(key)),
      #("holder", json.string(holder)),
      #("fencing_token", json.int(fencing_token)),
    ])
  send(client, Post, "/v1/semaphores/release", Some(body))
}

// --- idempotency ---

/// `GET /v1/idempotency?key=…` — inspect an active idempotency record.
pub fn idempotency_get(
  client: Client,
  key: String,
) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/idempotency?key=" <> enc(key), None)
}

/// `POST /v1/idempotency/claim` — claim a key; first claimant wins until TTL.
/// `metadata` is arbitrary JSON.
pub fn idempotency_claim(
  client: Client,
  key: String,
  owner: Option(String),
  ttl_ms: Option(Int),
  ttl: Option(String),
  metadata: Option(Json),
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [#("key", json.string(key))],
        opt_string("owner", owner),
        opt_int("ttl_ms", ttl_ms),
        opt_string("ttl", ttl),
        opt("metadata", metadata),
      ]),
    )
  send(client, Post, "/v1/idempotency/claim", Some(body))
}

/// `POST /v1/idempotency/complete` — mark a claim complete; `result` is arbitrary
/// JSON stored for replay.
pub fn idempotency_complete(
  client: Client,
  key: String,
  owner: String,
  fencing_token: Int,
  result: Option(Json),
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [
          #("key", json.string(key)),
          #("owner", json.string(owner)),
          #("fencing_token", json.int(fencing_token)),
        ],
        opt("result", result),
      ]),
    )
  send(client, Post, "/v1/idempotency/complete", Some(body))
}

// --- reader-writer locks ---

/// `POST /v1/rw/<key>/read` — acquire a shared read lock.
pub fn rw_acquire_read(
  client: Client,
  key: String,
  ttl_ms: Option(Int),
  wait: Bool,
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([opt_int("ttl_ms", ttl_ms), [#("wait", json.bool(wait))]]),
    )
  send(client, Post, "/v1/rw/" <> enc(key) <> "/read", Some(body))
}

/// `POST /v1/rw/<key>/read/end` — release a read lock by its lock id.
pub fn rw_end_read(
  client: Client,
  key: String,
  lock_id: String,
) -> Result(Dynamic, FiduciaError) {
  let body = json.object([#("lock_id", json.string(lock_id))])
  send(client, Post, "/v1/rw/" <> enc(key) <> "/read/end", Some(body))
}

/// `POST /v1/rw/<key>/write` — acquire an exclusive write lock.
pub fn rw_acquire_write(
  client: Client,
  key: String,
  ttl_ms: Option(Int),
  wait: Bool,
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([opt_int("ttl_ms", ttl_ms), [#("wait", json.bool(wait))]]),
    )
  send(client, Post, "/v1/rw/" <> enc(key) <> "/write", Some(body))
}

/// `POST /v1/rw/<key>/write/end` — release a write lock by its lock id.
pub fn rw_end_write(
  client: Client,
  key: String,
  lock_id: String,
) -> Result(Dynamic, FiduciaError) {
  let body = json.object([#("lock_id", json.string(lock_id))])
  send(client, Post, "/v1/rw/" <> enc(key) <> "/write/end", Some(body))
}

// --- config KV ---

/// `GET /v1/kv?key=…` — read a config key.
pub fn kv_get(client: Client, key: String) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/kv?key=" <> enc(key), None)
}

/// `PUT /v1/kv?key=…` — write a config key. `prev_revision` is a compare-and-swap
/// guard (0 = must-not-exist); when omitted the write is unconditional.
pub fn kv_put(
  client: Client,
  key: String,
  value: String,
  ttl_ms: Option(Int),
  prev_revision: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [#("value", json.string(value))],
        opt_int("ttl_ms", ttl_ms),
        opt_int("prev_revision", prev_revision),
      ]),
    )
  send(client, Put, "/v1/kv?key=" <> enc(key), Some(body))
}

/// `DELETE /v1/kv?key=…` — delete a config key.
pub fn kv_delete(client: Client, key: String) -> Result(Dynamic, FiduciaError) {
  send(client, Delete, "/v1/kv?key=" <> enc(key), None)
}

/// `GET /v1/kv?prefix=…` — list config keys under a prefix.
pub fn kv_list(
  client: Client,
  prefix: String,
) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/kv?prefix=" <> enc(prefix), None)
}

// --- rate limiting ---

/// `GET /v1/rate-limit/<tenant>/<key>` — current limiter state.
pub fn rate_limit_get(
  client: Client,
  tenant: String,
  key: String,
) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/rate-limit/" <> enc(tenant) <> "/" <> enc(key), None)
}

/// `POST /v1/rate-limit/<tenant>/<key>/check` — atomic check-and-decrement.
/// `algorithm` is `token_bucket` or `sliding_window`.
pub fn rate_limit_check(
  client: Client,
  tenant: String,
  key: String,
  algorithm: String,
  limit: Int,
  window_ms: Int,
  refill_per_second: Option(Float),
  cost: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [
          #("algorithm", json.string(algorithm)),
          #("limit", json.int(limit)),
          #("window_ms", json.int(window_ms)),
        ],
        opt_float("refill_per_second", refill_per_second),
        opt_int("cost", cost),
      ]),
    )
  send(
    client,
    Post,
    "/v1/rate-limit/" <> enc(tenant) <> "/" <> enc(key) <> "/check",
    Some(body),
  )
}

// --- cron & scheduling ---

/// `GET /v1/cron/schedules/<name>` — read a schedule definition.
pub fn schedule_get(
  client: Client,
  name: String,
) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/cron/schedules/" <> enc(name), None)
}

/// `PUT /v1/cron/schedules/<name>` — create/update a schedule. `target` is
/// arbitrary JSON, e.g. `{kind: "webhook", url: "…"}`. Provide exactly one of
/// `cron` / `one_shot_at_ms`.
pub fn schedule_upsert(
  client: Client,
  name: String,
  target: Json,
  cron: Option(String),
  one_shot_at_ms: Option(Int),
  delivery: Option(String),
  max_retries: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [#("target", target)],
        opt_string("cron", cron),
        opt_int("one_shot_at_ms", one_shot_at_ms),
        opt_string("delivery", delivery),
        opt_int("max_retries", max_retries),
      ]),
    )
  send(client, Put, "/v1/cron/schedules/" <> enc(name), Some(body))
}

/// `POST /v1/cron/schedules/<name>/runs` — record a fire; duplicate `fire_id` is
/// deduped (exactly-once).
pub fn schedule_record_run(
  client: Client,
  name: String,
  fire_id: String,
  fired_at_ms: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [#("fire_id", json.string(fire_id))],
        opt_int("fired_at_ms", fired_at_ms),
      ]),
    )
  send(client, Post, "/v1/cron/schedules/" <> enc(name) <> "/runs", Some(body))
}

/// `GET /v1/cron/schedules/<name>/history` — recent run history.
pub fn schedule_history(
  client: Client,
  name: String,
) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/cron/schedules/" <> enc(name) <> "/history", None)
}

// --- leader election ---

/// `GET /v1/elections/<name>` — observe the current holder.
pub fn election_get(
  client: Client,
  name: String,
) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/elections/" <> enc(name), None)
}

/// `POST /v1/elections/<name>/campaign` — campaign for leadership. `metadata`
/// (arbitrary JSON) is published on the leadership record.
pub fn election_campaign(
  client: Client,
  name: String,
  candidate: String,
  ttl_ms: Int,
  metadata: Option(Json),
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [#("candidate", json.string(candidate)), #("ttl_ms", json.int(ttl_ms))],
        opt("metadata", metadata),
      ]),
    )
  send(client, Post, "/v1/elections/" <> enc(name) <> "/campaign", Some(body))
}

/// `POST /v1/elections/<name>/renew` — extend the lease with the held token.
pub fn election_renew(
  client: Client,
  name: String,
  candidate: String,
  fencing_token: Int,
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object([
      #("candidate", json.string(candidate)),
      #("fencing_token", json.int(fencing_token)),
    ])
  send(client, Post, "/v1/elections/" <> enc(name) <> "/renew", Some(body))
}

/// `POST /v1/elections/<name>/resign` — step down with the held token.
pub fn election_resign(
  client: Client,
  name: String,
  candidate: String,
  fencing_token: Int,
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object([
      #("candidate", json.string(candidate)),
      #("fencing_token", json.int(fencing_token)),
    ])
  send(client, Post, "/v1/elections/" <> enc(name) <> "/resign", Some(body))
}

// --- service discovery ---

/// `GET /v1/services/<service>` — list live instances of a service.
pub fn service_instances(
  client: Client,
  service: String,
) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/services/" <> enc(service), None)
}

/// `PUT /v1/services/<service>/instances/<instance_id>` — register/refresh an
/// instance with a TTL lease and optional `metadata` (arbitrary JSON).
pub fn service_register(
  client: Client,
  service: String,
  instance_id: String,
  address: String,
  ttl_ms: Int,
  metadata: Option(Json),
) -> Result(Dynamic, FiduciaError) {
  let body =
    json.object(
      list.flatten([
        [#("address", json.string(address)), #("ttl_ms", json.int(ttl_ms))],
        opt("metadata", metadata),
      ]),
    )
  send(
    client,
    Put,
    "/v1/services/" <> enc(service) <> "/instances/" <> enc(instance_id),
    Some(body),
  )
}

/// `POST /v1/services/<service>/instances/<instance_id>/heartbeat` — renew a lease.
pub fn service_heartbeat(
  client: Client,
  service: String,
  instance_id: String,
  ttl_ms: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  let body = json.object(opt_int("ttl_ms", ttl_ms))
  send(
    client,
    Post,
    "/v1/services/"
      <> enc(service)
      <> "/instances/"
      <> enc(instance_id)
      <> "/heartbeat",
    Some(body),
  )
}

/// `DELETE /v1/services/<service>/instances/<instance_id>` — remove an instance.
pub fn service_deregister(
  client: Client,
  service: String,
  instance_id: String,
) -> Result(Dynamic, FiduciaError) {
  send(
    client,
    Delete,
    "/v1/services/" <> enc(service) <> "/instances/" <> enc(instance_id),
    None,
  )
}

/// `GET /v1/services` — list all registered services.
pub fn service_list(client: Client) -> Result(Dynamic, FiduciaError) {
  send(client, Get, "/v1/services", None)
}

// --- internals ---

// -- blocking acquire: poll loops behind must_lock / must_semaphore --

/// Resolve the holder id: caller-supplied, else a generated stable id.
fn resolve_holder(holder: Option(String)) -> String {
  case holder {
    Some(h) -> h
    None -> gen_holder()
  }
}

/// Pull a held grant out of an acquire response's `result.output`. `Some` only
/// when `acquired == true` with a fencing token; `None` means queued → poll.
fn output_grant(resp: Dynamic, key: String, holder: String) -> Option(Grant) {
  let decoder = {
    use acquired <- decode.optional_field("acquired", False, decode.bool)
    use token <- decode.optional_field(
      "fencing_token",
      None,
      decode.optional(decode.int),
    )
    use lease <- decode.optional_field(
      "lease_expires_ms",
      None,
      decode.optional(decode.int),
    )
    decode.success(#(acquired, token, lease))
  }
  case decode.run(resp, decode.at(["result", "output"], decoder)) {
    Ok(#(True, Some(token), lease)) ->
      Some(Grant(
        key: key,
        holder: holder,
        fencing_token: token,
        lease_expires_ms: lease,
      ))
    _ -> None
  }
}

/// True once an optional `max_retries` cap has been reached. Kept out of the
/// `case` guard so the client still compiles on Gleam 1.0 (ordering comparisons
/// in guards need 1.3+).
fn retries_exhausted(max_retries: Option(Int), attempt: Int) -> Bool {
  case max_retries {
    Some(cap) -> attempt >= cap
    None -> False
  }
}

/// Poll `lock_get(key)` until we hold the lock or the deadline / attempt cap is
/// hit. A union lock is held iff we hold its first member, so single-key polling
/// is correct here.
fn poll_lock(
  client: Client,
  key: String,
  holder: String,
  deadline: Int,
  retry: Retry,
  attempt: Int,
) -> Result(Grant, FiduciaError) {
  case retries_exhausted(retry.max_retries, attempt) {
    True -> Error(Timeout(retry.max_wait_ms))
    False -> {
      let remaining = deadline - now_ms()
      case remaining <= 0 {
        True -> Error(Timeout(retry.max_wait_ms))
        False -> {
          nap(retry.retry_interval_ms, remaining)
          use resp <- result.try(lock_get(client, key))
          case lock_held_by(resp, key, holder) {
            Some(grant) -> Ok(grant)
            None -> poll_lock(client, key, holder, deadline, retry, attempt + 1)
          }
        }
      }
    }
  }
}

/// Poll `semaphore_get(key)` until our holder holds a permit or the budget is
/// exhausted.
fn poll_semaphore(
  client: Client,
  key: String,
  holder: String,
  deadline: Int,
  retry: Retry,
  attempt: Int,
) -> Result(Grant, FiduciaError) {
  case retries_exhausted(retry.max_retries, attempt) {
    True -> Error(Timeout(retry.max_wait_ms))
    False -> {
      let remaining = deadline - now_ms()
      case remaining <= 0 {
        True -> Error(Timeout(retry.max_wait_ms))
        False -> {
          nap(retry.retry_interval_ms, remaining)
          use resp <- result.try(semaphore_get(client, key))
          case semaphore_held_by(resp, key, holder) {
            Some(grant) -> Ok(grant)
            None ->
              poll_semaphore(client, key, holder, deadline, retry, attempt + 1)
          }
        }
      }
    }
  }
}

/// `lock_get` response → `Some(Grant)` iff `resp.lock.holder == holder` with a
/// non-null fencing token.
fn lock_held_by(resp: Dynamic, key: String, holder: String) -> Option(Grant) {
  let decoder = {
    use who <- decode.field("holder", decode.string)
    use token <- decode.field("fencing_token", decode.int)
    use lease <- decode.optional_field(
      "lease_expires_ms",
      None,
      decode.optional(decode.int),
    )
    decode.success(#(who, token, lease))
  }
  case decode.run(resp, decode.at(["lock"], decoder)) {
    Ok(#(who, token, lease)) if who == holder ->
      Some(Grant(
        key: key,
        holder: holder,
        fencing_token: token,
        lease_expires_ms: lease,
      ))
    _ -> None
  }
}

/// `semaphore_get` response → `Some(Grant)` for the `semaphore.holders` entry
/// matching our holder with a non-null fencing token.
fn semaphore_held_by(
  resp: Dynamic,
  key: String,
  holder: String,
) -> Option(Grant) {
  let entry = {
    use who <- decode.field("holder", decode.string)
    use token <- decode.optional_field(
      "fencing_token",
      None,
      decode.optional(decode.int),
    )
    use lease <- decode.optional_field(
      "lease_expires_ms",
      None,
      decode.optional(decode.int),
    )
    decode.success(#(who, token, lease))
  }
  case
    decode.run(resp, decode.at(["semaphore", "holders"], decode.list(entry)))
  {
    Ok(holders) ->
      holders
      |> list.find_map(fn(h) {
        case h {
          #(who, Some(token), lease) if who == holder ->
            Ok(Grant(
              key: key,
              holder: holder,
              fencing_token: token,
              lease_expires_ms: lease,
            ))
          _ -> Error(Nil)
        }
      })
      |> option.from_result
    Error(_) -> None
  }
}

/// Sleep for `min(interval, remaining)` ms (both are > 0 at the call site).
fn nap(interval: Int, remaining: Int) -> Nil {
  case interval < remaining {
    True -> sleep(interval)
    False -> sleep(remaining)
  }
}

@external(erlang, "fiducia_ffi", "monotonic_ms")
fn now_ms() -> Int

@external(erlang, "fiducia_ffi", "sleep")
fn sleep(ms: Int) -> Nil

@external(erlang, "fiducia_ffi", "gen_holder")
fn gen_holder() -> String

/// Default per-request timeout (connect + response) in milliseconds. This equals
/// gleam_httpc's own default; it is pinned here so the value is explicit and does
/// not silently change if the library default changes.
const default_timeout_ms = 30_000

/// Transport configuration applied to every request. TLS verification stays ON;
/// the two safety-relevant knobs are pinned explicitly rather than left to the
/// library defaults:
///   * `follow_redirects: False` — a 3xx on a mutating POST/PUT/DELETE (e.g.
///     `/v1/locks/acquire`) must NOT be auto-followed, or the operation could be
///     re-submitted and duplicate a grant / FIFO slot; it surfaces as an `Http`
///     error (status >= 300) instead.
///   * `timeout: default_timeout_ms` — a finite default so a stalled connection
///     cannot hang the caller indefinitely.
fn http_config() -> httpc.Configuration {
  httpc.configure()
  |> httpc.follow_redirects(False)
  |> httpc.timeout(default_timeout_ms)
}

fn send(
  client: Client,
  method: Method,
  path: String,
  body: Option(Json),
) -> Result(Dynamic, FiduciaError) {
  let url = client.base <> path
  case request.to(url) {
    Error(_) ->
      Error(Transport("fiducia: could not build request url: " <> url))
    Ok(base_request) -> {
      let req =
        base_request
        |> request.set_method(method)
        |> apply_body(body)
      case httpc.dispatch(http_config(), req) {
        Error(err) ->
          Error(Transport("fiducia: transport error: " <> string.inspect(err)))
        Ok(response) -> {
          let parsed = decode_body(response.body)
          case response.status >= 300 {
            True -> Error(Http(status: response.status, body: parsed))
            False -> Ok(parsed)
          }
        }
      }
    }
  }
}

fn apply_body(
  req: request.Request(String),
  body: Option(Json),
) -> request.Request(String) {
  case body {
    None -> req
    Some(payload) ->
      req
      |> request.set_header("content-type", "application/json")
      |> request.set_body(json.to_string(payload))
  }
}

/// Parse a response body into a `Dynamic`. Empty body → JSON null; non-JSON is
/// wrapped as a JSON string so callers always get a value.
fn decode_body(body: String) -> Dynamic {
  case string.trim(body) {
    "" -> null_dynamic()
    _ ->
      case json.parse(body, decode.dynamic) {
        Ok(value) -> value
        Error(_) -> string_dynamic(body)
      }
  }
}

fn null_dynamic() -> Dynamic {
  let assert Ok(value) = json.parse("null", decode.dynamic)
  value
}

fn string_dynamic(raw: String) -> Dynamic {
  let assert Ok(value) =
    json.parse(json.to_string(json.string(raw)), decode.dynamic)
  value
}

/// Percent-encode a path segment or query value.
fn enc(value: String) -> String {
  uri.percent_encode(value)
}

fn drop_trailing_slashes(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> drop_trailing_slashes(string.drop_end(value, 1))
    False -> value
  }
}

fn opt(name: String, value: Option(Json)) -> List(#(String, Json)) {
  case value {
    Some(payload) -> [#(name, payload)]
    None -> []
  }
}

fn opt_string(name: String, value: Option(String)) -> List(#(String, Json)) {
  opt(name, option.map(value, json.string))
}

fn opt_int(name: String, value: Option(Int)) -> List(#(String, Json)) {
  opt(name, option.map(value, json.int))
}

fn opt_float(name: String, value: Option(Float)) -> List(#(String, Json)) {
  opt(name, option.map(value, json.float))
}
