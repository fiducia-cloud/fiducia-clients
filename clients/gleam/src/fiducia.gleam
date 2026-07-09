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
import gleam/string
import gleam/uri

/// A failed call: either a non-2xx HTTP response (`Http`, carrying the numeric
/// status and the parsed JSON body as a `Dynamic`) or a transport/network
/// failure (`Transport`).
pub type FiduciaError {
  Http(status: Int, body: Dynamic)
  Transport(message: String)
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

/// `lock_acquire` with `wait=true`: reserve a FIFO slot.
pub fn must_lock(
  client: Client,
  key: String,
  holder: Option(String),
  ttl_ms: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  lock_acquire(client, key, holder, ttl_ms, True)
}

/// Alias of `must_lock`.
pub fn lock(
  client: Client,
  key: String,
  holder: Option(String),
  ttl_ms: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  must_lock(client, key, holder, ttl_ms)
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

/// `semaphore_acquire` with `wait=true`.
pub fn must_semaphore(
  client: Client,
  key: String,
  limit: Int,
  holder: Option(String),
  ttl_ms: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  semaphore_acquire(client, key, limit, holder, ttl_ms, True)
}

/// Alias of `must_semaphore`.
pub fn semaphore(
  client: Client,
  key: String,
  limit: Int,
  holder: Option(String),
  ttl_ms: Option(Int),
) -> Result(Dynamic, FiduciaError) {
  must_semaphore(client, key, limit, holder, ttl_ms)
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
pub fn kv_list(client: Client, prefix: String) -> Result(Dynamic, FiduciaError) {
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

fn send(
  client: Client,
  method: Method,
  path: String,
  body: Option(Json),
) -> Result(Dynamic, FiduciaError) {
  let url = client.base <> path
  case request.to(url) {
    Error(_) -> Error(Transport("fiducia: could not build request url: " <> url))
    Ok(base_request) -> {
      let req =
        base_request
        |> request.set_method(method)
        |> apply_body(body)
      case httpc.send(req) {
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
