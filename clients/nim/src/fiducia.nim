## Fiducia HTTP client (Nim). Zero-dependency — stdlib std/httpclient + std/json.
## Implements PROTOCOL.md.
##
##   import fiducia
##   let c = newClient("https://api.fiducia.cloud")
##   let lock = c.lockAcquire("orders/checkout", ttlMs = some(30000))
##   let token = lock["result"]["output"]["fencing_token"]
##   discard c.lockRelease("orders/checkout", "worker-a", token)
##
## HTTPS targets require compiling with `-d:ssl` (links OpenSSL), as usual for
## std/httpclient. Ops return the parsed JSON body as a `JsonNode` (nil for an
## empty body) and raise `FiduciaError` on any HTTP status >= 300.

import std/[httpclient, json, uri, strutils, options]

export json, options

type
  FiduciaError* = ref object of CatchableError
    ## Raised when the server responds with an HTTP status >= 300.
    status*: int      ## numeric HTTP status code
    body*: JsonNode   ## parsed JSON error body (nil when the body was empty)

  Client* = ref object
    ## A thin Fiducia HTTP client. Build one with `newClient`.
    baseUrl*: string
    timeout*: int     ## per-request timeout in milliseconds (-1 = no timeout)

proc newFiduciaError(status: int, body: JsonNode): FiduciaError =
  new(result)
  result.status = status
  result.body = body
  result.msg = "fiducia: HTTP " & $status

proc enc(s: string): string =
  ## Percent-encode a string for use in a path segment or query value.
  ## `usePlus = false` so a space is emitted as `%20` (a literal `+` would be
  ## wrong inside a path segment) rather than `+`; `/` becomes `%2F` so a key
  ## or name never leaks an extra path segment.
  encodeUrl(s, usePlus = false)

proc request(c: Client, meth: HttpMethod, path: string, body: JsonNode = nil): JsonNode =
  let client = newHttpClient(timeout = c.timeout)
  try:
    let headers = newHttpHeaders()
    var payload = ""
    if body != nil:
      headers["Content-Type"] = "application/json"
      payload = $body
    let resp = client.request(c.baseUrl & path, httpMethod = meth,
                              body = payload, headers = headers)
    let raw = resp.body
    var status = 0
    let parts = resp.status.splitWhitespace()
    if parts.len > 0:
      try:
        status = parseInt(parts[0])
      except ValueError:
        status = 0
    var data: JsonNode = nil
    if raw.len > 0:
      try:
        data = parseJson(raw)
      except JsonParsingError:
        # A non-JSON body (e.g. an HTML 502 from a proxy, or a plain-text
        # error) must not crash the client: carry it as a raw JSON string so
        # error handlers can still inspect `FiduciaError.body`.
        data = newJString(raw)
    if status >= 300:
      raise newFiduciaError(status, data)
    result = data
  finally:
    client.close()

proc newClient*(baseUrl: string, timeout: int = -1): Client =
  ## Build a client. Trailing slashes on `baseUrl` are trimmed. `timeout` is the
  ## per-request timeout in milliseconds (-1 = no timeout).
  var b = baseUrl
  b.removeSuffix('/')
  Client(baseUrl: b, timeout: timeout)

# --- misc ---
proc health*(c: Client): JsonNode =
  c.request(HttpGet, "/healthz")

proc status*(c: Client): JsonNode =
  c.request(HttpGet, "/v1/status")

# --- locks ---
proc lockGet*(c: Client, key: string): JsonNode =
  c.request(HttpGet, "/v1/locks?key=" & enc(key))

proc lockAcquire*(c: Client, key: string, holder = none(string),
                  ttlMs = none(int), wait = true): JsonNode =
  var body = %*{"key": key, "wait": wait}
  if holder.isSome: body["holder"] = %holder.get
  if ttlMs.isSome: body["ttl_ms"] = %ttlMs.get
  c.request(HttpPost, "/v1/locks/acquire", body)

proc lockAcquireMany*(c: Client, keys: seq[string], holder = none(string),
                      ttlMs = none(int), wait = true): JsonNode =
  ## Multi-key UNION lock: all-or-nothing across the whole set.
  var body = %*{"keys": keys, "wait": wait}
  if holder.isSome: body["holder"] = %holder.get
  if ttlMs.isSome: body["ttl_ms"] = %ttlMs.get
  c.request(HttpPost, "/v1/locks/acquire", body)

proc tryLock*(c: Client, key: string, holder = none(string),
              ttlMs = none(int)): JsonNode =
  c.lockAcquire(key, holder, ttlMs, wait = false)

proc mustLock*(c: Client, key: string, holder = none(string),
               ttlMs = none(int)): JsonNode =
  c.lockAcquire(key, holder, ttlMs, wait = true)

proc lock*(c: Client, key: string, holder = none(string),
           ttlMs = none(int)): JsonNode =
  c.mustLock(key, holder, ttlMs)

proc lockRelease*(c: Client, key: string, holder: string,
                  fencingToken: JsonNode): JsonNode =
  ## `key` is accepted for symmetry but is not sent in the body.
  var body = %*{"holder": holder}
  body["fencing_token"] = fencingToken
  c.request(HttpPost, "/v1/locks/release", body)

# --- semaphores ---
proc semaphoreGet*(c: Client, key: string): JsonNode =
  c.request(HttpGet, "/v1/semaphores?key=" & enc(key))

proc semaphoreAcquire*(c: Client, key: string, limit: int,
                       holder = none(string), ttlMs = none(int),
                       wait = true): JsonNode =
  var body = %*{"key": key, "limit": limit, "wait": wait}
  if holder.isSome: body["holder"] = %holder.get
  if ttlMs.isSome: body["ttl_ms"] = %ttlMs.get
  c.request(HttpPost, "/v1/semaphores/acquire", body)

proc trySemaphore*(c: Client, key: string, limit: int, holder = none(string),
                   ttlMs = none(int)): JsonNode =
  c.semaphoreAcquire(key, limit, holder, ttlMs, wait = false)

proc mustSemaphore*(c: Client, key: string, limit: int, holder = none(string),
                    ttlMs = none(int)): JsonNode =
  c.semaphoreAcquire(key, limit, holder, ttlMs, wait = true)

proc semaphore*(c: Client, key: string, limit: int, holder = none(string),
                ttlMs = none(int)): JsonNode =
  c.mustSemaphore(key, limit, holder, ttlMs)

proc semaphoreRelease*(c: Client, key: string, holder: string,
                       fencingToken: JsonNode): JsonNode =
  var body = %*{"key": key, "holder": holder}
  body["fencing_token"] = fencingToken
  c.request(HttpPost, "/v1/semaphores/release", body)

# --- idempotency ---
proc idempotencyGet*(c: Client, key: string): JsonNode =
  c.request(HttpGet, "/v1/idempotency?key=" & enc(key))

proc idempotencyClaim*(c: Client, key: string, owner = none(string),
                       ttlMs = none(int), ttl = none(string),
                       metadata: JsonNode = nil): JsonNode =
  var body = %*{"key": key}
  if owner.isSome: body["owner"] = %owner.get
  if ttlMs.isSome: body["ttl_ms"] = %ttlMs.get
  if ttl.isSome: body["ttl"] = %ttl.get
  if metadata != nil: body["metadata"] = metadata
  c.request(HttpPost, "/v1/idempotency/claim", body)

proc idempotencyComplete*(c: Client, key: string, owner: string,
                          fencingToken: JsonNode, res: JsonNode = nil): JsonNode =
  ## `res` is stored as the replayable `result` object when provided.
  var body = %*{"key": key, "owner": owner}
  body["fencing_token"] = fencingToken
  if res != nil: body["result"] = res
  c.request(HttpPost, "/v1/idempotency/complete", body)

# --- reader-writer locks ---
proc rwAcquireRead*(c: Client, key: string, ttlMs = none(int),
                    wait = true): JsonNode =
  var body = %*{"wait": wait}
  if ttlMs.isSome: body["ttl_ms"] = %ttlMs.get
  c.request(HttpPost, "/v1/rw/" & enc(key) & "/read", body)

proc rwEndRead*(c: Client, key: string, lockId: string): JsonNode =
  c.request(HttpPost, "/v1/rw/" & enc(key) & "/read/end", %*{"lock_id": lockId})

proc rwAcquireWrite*(c: Client, key: string, ttlMs = none(int),
                     wait = true): JsonNode =
  var body = %*{"wait": wait}
  if ttlMs.isSome: body["ttl_ms"] = %ttlMs.get
  c.request(HttpPost, "/v1/rw/" & enc(key) & "/write", body)

proc rwEndWrite*(c: Client, key: string, lockId: string): JsonNode =
  c.request(HttpPost, "/v1/rw/" & enc(key) & "/write/end", %*{"lock_id": lockId})

# --- config KV ---
proc kvGet*(c: Client, key: string): JsonNode =
  c.request(HttpGet, "/v1/kv?key=" & enc(key))

proc kvPut*(c: Client, key: string, value: JsonNode, ttlMs = none(int),
            prevRevision = none(int)): JsonNode =
  ## `prevRevision` is a compare-and-swap guard (0 = must-not-exist).
  var body = newJObject()
  body["value"] = value
  if ttlMs.isSome: body["ttl_ms"] = %ttlMs.get
  if prevRevision.isSome: body["prev_revision"] = %prevRevision.get
  c.request(HttpPut, "/v1/kv?key=" & enc(key), body)

proc kvDelete*(c: Client, key: string): JsonNode =
  c.request(HttpDelete, "/v1/kv?key=" & enc(key))

proc kvList*(c: Client, prefix: string): JsonNode =
  c.request(HttpGet, "/v1/kv?prefix=" & enc(prefix))

# --- rate limiting ---
proc rateLimitGet*(c: Client, tenant, key: string): JsonNode =
  c.request(HttpGet, "/v1/rate-limit/" & enc(tenant) & "/" & enc(key))

proc rateLimitCheck*(c: Client, tenant, key, algorithm: string, limit: int,
                     windowMs: int, refillPerSecond = none(float),
                     cost = none(int)): JsonNode =
  var body = %*{"algorithm": algorithm, "limit": limit, "window_ms": windowMs}
  if refillPerSecond.isSome: body["refill_per_second"] = %refillPerSecond.get
  if cost.isSome: body["cost"] = %cost.get
  c.request(HttpPost, "/v1/rate-limit/" & enc(tenant) & "/" & enc(key) & "/check", body)

# --- cron & scheduling ---
proc scheduleGet*(c: Client, name: string): JsonNode =
  c.request(HttpGet, "/v1/cron/schedules/" & enc(name))

proc scheduleUpsert*(c: Client, name: string, target: JsonNode,
                     cron = none(string), oneShotAtMs = none(int),
                     delivery = none(string), maxRetries = none(int)): JsonNode =
  ## `target` is an arbitrary object, e.g. %*{"kind": "webhook", "url": "..."}.
  var body = newJObject()
  body["target"] = target
  if cron.isSome: body["cron"] = %cron.get
  if oneShotAtMs.isSome: body["one_shot_at_ms"] = %oneShotAtMs.get
  if delivery.isSome: body["delivery"] = %delivery.get
  if maxRetries.isSome: body["max_retries"] = %maxRetries.get
  c.request(HttpPut, "/v1/cron/schedules/" & enc(name), body)

proc scheduleRecordRun*(c: Client, name, fireId: string,
                        firedAtMs = none(int)): JsonNode =
  var body = %*{"fire_id": fireId}
  if firedAtMs.isSome: body["fired_at_ms"] = %firedAtMs.get
  c.request(HttpPost, "/v1/cron/schedules/" & enc(name) & "/runs", body)

proc scheduleHistory*(c: Client, name: string): JsonNode =
  c.request(HttpGet, "/v1/cron/schedules/" & enc(name) & "/history")

# --- leader election ---
proc electionGet*(c: Client, name: string): JsonNode =
  c.request(HttpGet, "/v1/elections/" & enc(name))

proc electionCampaign*(c: Client, name, candidate: string, ttlMs: int,
                       metadata: JsonNode = nil): JsonNode =
  var body = %*{"candidate": candidate, "ttl_ms": ttlMs}
  if metadata != nil: body["metadata"] = metadata
  c.request(HttpPost, "/v1/elections/" & enc(name) & "/campaign", body)

proc electionRenew*(c: Client, name, candidate: string,
                    fencingToken: JsonNode): JsonNode =
  var body = %*{"candidate": candidate}
  body["fencing_token"] = fencingToken
  c.request(HttpPost, "/v1/elections/" & enc(name) & "/renew", body)

proc electionResign*(c: Client, name, candidate: string,
                     fencingToken: JsonNode): JsonNode =
  var body = %*{"candidate": candidate}
  body["fencing_token"] = fencingToken
  c.request(HttpPost, "/v1/elections/" & enc(name) & "/resign", body)

# --- service discovery ---
proc serviceInstances*(c: Client, service: string): JsonNode =
  c.request(HttpGet, "/v1/services/" & enc(service))

proc serviceRegister*(c: Client, service, instanceId, address: string,
                      ttlMs: int, metadata: JsonNode = nil): JsonNode =
  var body = %*{"address": address, "ttl_ms": ttlMs}
  if metadata != nil: body["metadata"] = metadata
  c.request(HttpPut, "/v1/services/" & enc(service) & "/instances/" &
            enc(instanceId), body)

proc serviceHeartbeat*(c: Client, service, instanceId: string,
                       ttlMs = none(int)): JsonNode =
  var body = newJObject()
  if ttlMs.isSome: body["ttl_ms"] = %ttlMs.get
  c.request(HttpPost, "/v1/services/" & enc(service) & "/instances/" &
            enc(instanceId) & "/heartbeat", body)

proc serviceDeregister*(c: Client, service, instanceId: string): JsonNode =
  c.request(HttpDelete, "/v1/services/" & enc(service) & "/instances/" &
            enc(instanceId))

proc serviceList*(c: Client): JsonNode =
  c.request(HttpGet, "/v1/services")
