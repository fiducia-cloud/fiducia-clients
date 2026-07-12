# Fiducia client (Nim)

A thin, dependency-light HTTP client for [fiducia.cloud](https://fiducia.cloud).
Zero third-party dependencies — it uses only the standard library
(`std/httpclient` for transport, `std/json` for bodies). Implements
`PROTOCOL.md`.

## Install

With Nimble:

```sh
nimble install fiducia
```

Or add it to your project's `.nimble` file:

```nim
requires "fiducia >= 0.1.0"
```

The package can also be consumed directly from a git tag.

> HTTPS endpoints require building with `-d:ssl` (links OpenSSL), which is the
> standard requirement for `std/httpclient`.

## Usage

```nim
import fiducia

let c = newClient("https://api.fiducia.cloud")

# Acquire a lock, then release it with its fencing token.
let lock = c.lockAcquire("orders/checkout", ttlMs = some(30000))
let token = lock["result"]["output"]["fencing_token"]
discard c.lockRelease("orders/checkout", "worker-a", token)

# Config KV with a compare-and-swap guard (0 = must-not-exist).
discard c.kvPut("features/checkout", %*{"enabled": true}, prevRevision = some(0))
echo c.kvGet("features/checkout")
```

Every operation takes the `Client` first and returns the parsed JSON body as a
`JsonNode` (`nil` for an empty body). Optional arguments use `Option[T]` (pass
`some(x)`; omit to leave the field out of the request — this matters for
compare-and-swap semantics). Arbitrary-JSON arguments (`value`, `target`,
`metadata`, `result`) and fencing tokens are passed as `JsonNode`.

### Blocking acquire

`tryLock` / `trySemaphore` are single-shot (`wait:false`) and return the raw
acquire response. The blocking helpers `mustLock` / `lock` and `mustSemaphore` /
`semaphore` actually **block until the grant is held**: the server does not hold
the connection on `wait:true` (it returns a queued ticket immediately), so they
acquire and then poll `lockGet` / `semaphoreGet` until this holder is granted, or
raise `LockTimeout` when the wait budget elapses. They return a held grant you
can release: `{key, holder, fencing_token, lease_expires_ms}`.

```nim
let g = c.mustLock("orders/checkout", ttlMs = some(30000),
                   maxWaitMs = 30000, retryIntervalMs = 250)
discard c.lockRelease(g["key"].getStr, g["holder"].getStr, g["fencing_token"])
```

Knobs (with defaults): `holder` (generated `fdc-…` when omitted), `ttlMs`,
`maxWaitMs = 30000`, `retryIntervalMs = 250`, `maxRetries` (unbounded by default).

## Errors

Any HTTP status `>= 300` raises a `FiduciaError`:

```nim
try:
  discard c.status()
except FiduciaError as e:
  echo e.status   # numeric HTTP status
  echo e.body     # parsed JSON error body (or nil)
```

The blocking `mustLock` / `lock` / `mustSemaphore` / `semaphore` raise
`LockTimeout` (fields `keys`, `waitedMs`) if the grant is not held within
`maxWaitMs`.

## Method surface

Locks (`lockGet`, `lockAcquire`, `lockAcquireMany`, `tryLock`, `mustLock`,
`lock`, `lockRelease`), semaphores (`semaphoreGet`, `semaphoreAcquire`,
`trySemaphore`, `mustSemaphore`, `semaphore`, `semaphoreRelease`), idempotency
(`idempotencyGet`, `idempotencyClaim`, `idempotencyComplete`), reader-writer
locks (`rwAcquireRead`, `rwEndRead`, `rwAcquireWrite`, `rwEndWrite`), config KV
(`kvGet`, `kvPut`, `kvDelete`, `kvList`), rate limiting (`rateLimitGet`,
`rateLimitCheck`), cron (`scheduleGet`, `scheduleUpsert`, `scheduleRecordRun`,
`scheduleHistory`), leader election (`electionGet`, `electionCampaign`,
`electionRenew`, `electionResign`), service discovery (`serviceInstances`,
`serviceRegister`, `serviceHeartbeat`, `serviceDeregister`, `serviceList`), and
health (`health`, `status`).

## License

Proprietary. No open-source license has been granted for this package yet. All
rights are reserved unless fiducia.cloud grants a separate license.
