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
##
## The blocking helpers `mustLock`/`lock` and `mustSemaphore`/`semaphore` do NOT
## just set `wait=true` and return — the server does not hold the connection, it
## returns a queued ticket immediately. They acquire-then-poll (`lockGet` /
## `semaphoreGet`) until the grant is actually held, and raise `LockTimeout` if
## the wait budget (`maxWaitMs`, default 30s) elapses first. They return a held
## grant object `{key, holder, fencing_token, lease_expires_ms}` you can release.

import std/[httpclient, json, uri, strutils, options, os, monotimes, times,
            sysrand]

export json, options

type
  FiduciaError* = ref object of CatchableError
    ## Raised when the server responds with an HTTP status >= 300.
    status*: int      ## numeric HTTP status code
    body*: JsonNode   ## parsed JSON error body (nil when the body was empty)

  LockTimeout* = ref object of CatchableError
    ## Raised by the blocking helpers (`mustLock`/`lock`, `mustSemaphore`/
    ## `semaphore`) when the wait budget elapses before the grant is held.
    keys*: seq[string]  ## the key(s) that were waited on
    waitedMs*: int      ## the wait budget (ms) that elapsed

  Client* = ref object
    ## A thin Fiducia HTTP client. Build one with `newClient`.
    baseUrl*: string
    timeout*: int     ## per-request socket timeout in milliseconds (-1 = wait
                      ## indefinitely). Defaults to 30_000 via `newClient`.

proc newFiduciaError(status: int, body: JsonNode): FiduciaError =
  new(result)
  result.status = status
  result.body = body
  result.msg = "fiducia: HTTP " & $status

proc newLockTimeout(keys: seq[string], waitedMs: int): LockTimeout =
  new(result)
  result.keys = keys
  result.waitedMs = waitedMs
  result.msg = "fiducia: timed out after " & $waitedMs & "ms waiting for " &
    keys.join(", ")

proc enc(s: string): string =
  ## Percent-encode a string for use in a path segment or query value.
  ## `usePlus = false` so a space is emitted as `%20` (a literal `+` would be
  ## wrong inside a path segment) rather than `+`; `/` becomes `%2F` so a key
  ## or name never leaks an extra path segment.
  encodeUrl(s, usePlus = false)

proc request(c: Client, meth: HttpMethod, path: string, body: JsonNode = nil): JsonNode =
  # maxRedirects = 0: never auto-follow a 3xx. The fixed load balancer routes to
  # the owning shard leader internally, so a redirect is not expected; following
  # one would re-issue a mutating POST/PUT/DELETE and could duplicate a lock
  # grant or FIFO queue slot. A 3xx instead surfaces through the normal path
  # (status >= 300 -> FiduciaError), which is the safe behavior.
  let client = newHttpClient(maxRedirects = 0, timeout = c.timeout)
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

proc newClient*(baseUrl: string, timeout: int = 30_000): Client =
  ## Build a client. Trailing slashes on `baseUrl` are trimmed. `timeout` is the
  ## per-request socket timeout in milliseconds; it defaults to 30_000 (30s) so a
  ## dead or hung connection cannot block forever. Waiting is client-driven — the
  ## server never holds a `wait:true` request open (it returns a queued result
  ## immediately) — so a finite default is safe. Pass `-1` to wait indefinitely.
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

# --- blocking-acquire helpers ---
# The server does not hold the connection on wait:true; it reserves a FIFO slot
# and returns a queued ticket immediately. So the blocking helpers acquire, then
# poll until the grant is actually held (or the wait budget elapses).
proc genHolder(): string =
  ## A stable, unique holder id for one logical acquire, e.g. "fdc-9f1c4e...".
  result = "fdc-"
  for b in urandom(8): result.add toHex(b.int, 2).toLowerAscii

proc jsonOutput(resp: JsonNode): JsonNode =
  ## `resp.result.output`, nil-safe (an empty object when absent).
  result = resp{"result", "output"}
  if result == nil: result = newJObject()

proc mkGrant(key, holder: string, src: JsonNode): JsonNode =
  ## A held grant the caller can release. `fencing_token` is kept as its native
  ## JSON node so 64-bit tokens keep full precision.
  result = newJObject()
  result["key"] = %key
  result["holder"] = %holder
  let ft = src{"fencing_token"}
  result["fencing_token"] = (if ft != nil: ft else: newJNull())
  let le = src{"lease_expires_ms"}
  result["lease_expires_ms"] = (if le != nil: le else: newJNull())

proc heldBy(node: JsonNode, holder: string): bool =
  ## True when `node` shows `holder` holding with a non-null fencing_token.
  let ft = node{"fencing_token"}
  node != nil and node{"holder"}.getStr == holder and ft != nil and
    ft.kind != JNull

proc pollLock(c: Client, key, holder: string, maxWaitMs, retryIntervalMs: int,
              maxRetries: Option[int]): JsonNode =
  let deadline = getMonoTime() + initDuration(milliseconds = maxWaitMs)
  var attempts = 0
  while maxRetries.isNone or attempts < maxRetries.get:
    inc attempts
    let remaining = inMilliseconds(deadline - getMonoTime()).int
    if remaining <= 0: break
    sleep(min(retryIntervalMs, remaining))
    let lk = c.lockGet(key){"lock"}
    if lk.heldBy(holder): return mkGrant(key, holder, lk)
  raise newLockTimeout(@[key], maxWaitMs)

proc mustLock*(c: Client, key: string, holder = none(string), ttlMs = none(int),
               maxWaitMs = 30_000, retryIntervalMs = 250,
               maxRetries = none(int)): JsonNode =
  ## Block until the lock is actually held, else raise `LockTimeout` after
  ## `maxWaitMs`. Acquires with wait:true, then polls `lockGet` every
  ## `retryIntervalMs`. Returns a held grant `{key, holder, fencing_token,
  ## lease_expires_ms}`; a holder is generated when none is given.
  let h = if holder.isSome: holder.get else: genHolder()
  let o = jsonOutput(c.lockAcquire(key, some(h), ttlMs, wait = true))
  if o{"acquired"}.getBool: return mkGrant(key, h, o)
  c.pollLock(key, h, maxWaitMs, retryIntervalMs, maxRetries)

proc lock*(c: Client, key: string, holder = none(string), ttlMs = none(int),
           maxWaitMs = 30_000, retryIntervalMs = 250,
           maxRetries = none(int)): JsonNode =
  c.mustLock(key, holder, ttlMs, maxWaitMs, retryIntervalMs, maxRetries)

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

proc pollSemaphore(c: Client, key, holder: string, maxWaitMs,
                   retryIntervalMs: int, maxRetries: Option[int]): JsonNode =
  let deadline = getMonoTime() + initDuration(milliseconds = maxWaitMs)
  var attempts = 0
  while maxRetries.isNone or attempts < maxRetries.get:
    inc attempts
    let remaining = inMilliseconds(deadline - getMonoTime()).int
    if remaining <= 0: break
    sleep(min(retryIntervalMs, remaining))
    let holders = c.semaphoreGet(key){"semaphore", "holders"}
    if holders != nil and holders.kind == JArray:
      for slot in holders:
        if slot.heldBy(holder): return mkGrant(key, holder, slot)
  raise newLockTimeout(@[key], maxWaitMs)

proc mustSemaphore*(c: Client, key: string, limit: int, holder = none(string),
                    ttlMs = none(int), maxWaitMs = 30_000,
                    retryIntervalMs = 250, maxRetries = none(int)): JsonNode =
  ## Block until a permit is actually held, else raise `LockTimeout` after
  ## `maxWaitMs`. Acquires with wait:true, then polls `semaphoreGet` for this
  ## holder's slot. Returns a held grant `{key, holder, fencing_token,
  ## lease_expires_ms}`; a holder is generated when none is given.
  let h = if holder.isSome: holder.get else: genHolder()
  let o = jsonOutput(c.semaphoreAcquire(key, limit, some(h), ttlMs, wait = true))
  if o{"acquired"}.getBool: return mkGrant(key, h, o)
  c.pollSemaphore(key, h, maxWaitMs, retryIntervalMs, maxRetries)

proc semaphore*(c: Client, key: string, limit: int, holder = none(string),
                ttlMs = none(int), maxWaitMs = 30_000, retryIntervalMs = 250,
                maxRetries = none(int)): JsonNode =
  c.mustSemaphore(key, limit, holder, ttlMs, maxWaitMs, retryIntervalMs,
                  maxRetries)

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
