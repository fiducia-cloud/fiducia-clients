# fiducia_client (Gleam)

Thin, dependency-light HTTP client for [fiducia.cloud](https://github.com/fiducia-cloud/fiducia-clients):
distributed locks, semaphores, idempotency keys, reader-writer locks, config KV,
rate limiting, cron/scheduling, leader election, and service discovery.

Implements the shared `PROTOCOL.md` contract. Transport is
[`gleam_httpc`](https://hex.pm/packages/gleam_httpc); bodies are encoded/decoded
with [`gleam_json`](https://hex.pm/packages/gleam_json). Runs on the Erlang
target (`inets` + `ssl` are pulled in as OTP application dependencies, so a
released app starts them automatically).

## Add it to your project

```sh
gleam add fiducia_client
```

## Quick start

```gleam
import fiducia
import gleam/dynamic/decode
import gleam/option.{None, Some}

pub fn main() {
  let client = fiducia.new("https://api.fiducia.cloud")

  // Acquire a 30s lock. Optional arguments are `Option` values.
  let assert Ok(grant) =
    fiducia.lock_acquire(client, "orders/checkout", Some("worker-a"), Some(30_000), True)

  // Responses are `Dynamic` — pull typed fields with a `gleam/dynamic/decode`
  // decoder instead of a forced schema.
  let token_decoder = decode.at(["result", "output", "fencing_token"], decode.int)
  let assert Ok(token) = decode.run(grant, token_decoder)

  let assert Ok(_) =
    fiducia.lock_release(client, "orders/checkout", "worker-a", token)
}
```

## Return values and errors

Most methods return `Result(Dynamic, FiduciaError)`; the blocking `must_lock` /
`lock` / `must_semaphore` / `semaphore` helpers return `Result(Grant, FiduciaError)`
(see [Blocking acquire](#blocking-acquire)).

- `Ok(Dynamic)` — the parsed JSON response body (an empty body decodes to JSON
  `null`). Decode it with `gleam/dynamic/decode`.
- `Error(Http(status, body))` — a non-2xx response. `status: Int` and `body`
  is the parsed JSON body as a `Dynamic`.
- `Error(Transport(message))` — a network/transport failure (`message: String`).
- `Error(Timeout(waited_ms))` — a blocking acquire never became held within its
  wait budget (`waited_ms: Int`).

```gleam
case fiducia.kv_get(client, "feature/checkout") {
  Ok(value) -> handle(value)
  Error(fiducia.Http(status, _body)) -> log_http(status)
  Error(fiducia.Transport(message)) -> log_transport(message)
}
```

## Optional arguments

Gleam has no keyword/default arguments, so optional protocol fields are passed as
`Option` values and are **omitted from the JSON body when `None`** (this matters
for compare-and-swap semantics such as `kv_put`'s `prev_revision`). Arbitrary
JSON fields (`metadata`, `result`, `target`) are `gleam/json` `Json` values.

```gleam
import gleam/json

// Conditional write: only create if the key does not exist (prev_revision = 0).
fiducia.kv_put(client, "config/mode", "canary", None, Some(0))

// Register a service instance with free-form metadata.
let meta = json.object([#("region", json.string("us-east-1"))])
fiducia.service_register(client, "api", "i-1", "10.0.0.1:9000", 10_000, Some(meta))
```

## Method reference

```
misc              health · status
locks             lock_get · lock_acquire · lock_acquire_many · try_lock ·
                  must_lock · lock · lock_release
semaphores        semaphore_get · semaphore_acquire · try_semaphore ·
                  must_semaphore · semaphore · semaphore_release
idempotency       idempotency_get · idempotency_claim · idempotency_complete
reader-writer     rw_acquire_read · rw_end_read · rw_acquire_write · rw_end_write
config KV         kv_get · kv_put · kv_delete · kv_list
rate limiting     rate_limit_get · rate_limit_check
cron/scheduling   schedule_get · schedule_upsert · schedule_record_run ·
                  schedule_history
leader election   election_get · election_campaign · election_renew ·
                  election_resign
service discovery service_instances · service_register · service_heartbeat ·
                  service_deregister · service_list
```

`try_*` / `must_*` / `lock` / `semaphore` are thin helpers that flip the `wait`
flag on the matching `*_acquire` call; they do no client-side polling.

## Publishing

Published to [Hex](https://hex.pm) via the repo's publish wrapper:

```sh
./publish.sh --release   # delegates to ../../scripts/publish-client.sh gleam
```

## License

Proprietary / UNLICENSED. See [`LICENSE.txt`](./LICENSE.txt).
