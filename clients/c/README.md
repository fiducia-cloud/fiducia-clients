# Fiducia client (C)

A thin C11 HTTP wrapper over the Fiducia coordination API. Built on **libcurl**.
Implements [`PROTOCOL.md`](../../PROTOCOL.md).

## You bring your own JSON parser

C has no standard JSON library, so **this client does not parse responses**. Each
operation returns the raw HTTP status and the raw, NUL-terminated response body:

```c
typedef struct {
    long status; /* HTTP status code, or 0 if the request never completed */
    char *body;  /* NUL-terminated response body, may be NULL when empty */
} fiducia_response;
```

Parse `body` with whatever JSON library you already use (cJSON, jansson,
yyjson, ...). Likewise, the `*_json` parameters (`metadata_json`, `target_json`,
`result_json`) take a **raw JSON object string** that is passed through verbatim
— you are responsible for producing valid JSON there.

**Non-2xx is not an error at this layer.** Every op returns `0` (`FIDUCIA_OK`)
whenever the HTTP round-trip completed; you then inspect `.status` yourself. A
**negative** return means the request never reached a server:

| code | meaning |
|------|---------|
| `0`  | `FIDUCIA_OK` — round-trip completed; check `.status` |
| `-1` | `FIDUCIA_ERR_ARG` — a required pointer argument was NULL |
| `-2` | `FIDUCIA_ERR_MEMORY` — out of memory building the request |
| `-3` | `FIDUCIA_ERR_TRANSPORT` — libcurl could not complete the request |

## Requirements

- A C11 compiler (`cc`/`gcc`/`clang`).
- **libcurl** development headers and library (`-lcurl`). On Debian/Ubuntu:
  `apt install libcurl4-openssl-dev`; on macOS libcurl ships with the SDK;
  with vcpkg/conan use the `curl` package.

## Build

### CMake (recommended)

```cmake
add_subdirectory(clients/c)      # provides the `fiducia::fiducia` target
target_link_libraries(my_app PRIVATE fiducia::fiducia)
```

`find_package(CURL REQUIRED)` is done for you and libcurl is linked
transitively.

### Directly with a compiler

Only two files are needed — drop `fiducia.h` and `fiducia.c` into your project:

```sh
cc -std=c11 -c fiducia.c
cc my_app.c fiducia.o -lcurl -o my_app
```

## Usage

```c
#include "fiducia.h"
#include <stdio.h>

int main(void) {
    fiducia_client *c = fiducia_client_new("https://api.fiducia.cloud");
    /* optional: fiducia_client_set_timeout_ms(c, 5000); */

    fiducia_response r;

    /* Try-acquire a lock (wait = 0). ttl_ms <= 0 omits the field. */
    if (fiducia_lock_acquire(c, "orders/checkout", "worker-a", 30000, 0, &r) == 0) {
        printf("HTTP %ld: %s\n", r.status, r.body ? r.body : "(empty)");
        /* parse r.body with your JSON lib to read result.output.fencing_token,
           then: fiducia_lock_release(c, "orders/checkout", "worker-a", token, &r2); */
    }
    fiducia_response_free(&r);

    /* Config KV: value required; ttl_ms <= 0 omits; prev_revision < 0 omits. */
    fiducia_kv_put(c, "flags/new-ui", "on", 60000, -1, &r);
    fiducia_response_free(&r);

    /* Raw-JSON parameters are passed through verbatim: */
    fiducia_election_campaign(c, "invoice-reconciler/leader", "pod-a", 15000,
                              "{\"region\":\"us-east-1\"}", &r);
    fiducia_response_free(&r);

    fiducia_client_free(c);
    return 0;
}
```

### Argument conventions

- `holder` / `owner` / `candidate` / optional strings: pass `NULL` to omit.
- Optional `ttl_ms`: pass `<= 0` to omit the field.
- Other optional numbers (`prev_revision`, `cost`, `one_shot_at_ms`,
  `fired_at_ms`, `max_retries`, `refill_per_second`): pass a **negative** value
  to omit (so `0` is sent explicitly — this matters for CAS on `prev_revision`).
- `*_json` parameters: raw JSON object string, or `NULL` to omit.
- All interpolated keys/names/services/tenants/prefixes are percent-encoded for
  you via `curl_easy_escape`.

### Memory & threading

- Always call `fiducia_response_free(&r)` on a response (safe after any return,
  including negatives and on a zeroed struct).
- The first `fiducia_client_new()` performs a one-time
  `curl_global_init(CURL_GLOBAL_DEFAULT)`. In a multi-threaded program, call
  `curl_global_init()` yourself before spawning threads (a libcurl requirement).
  A `fiducia_client` holds no socket state and may be shared across threads.
- Numeric fields use `long`; this client targets LP64 platforms (64-bit Linux,
  macOS) where fencing tokens fit comfortably.

## Method surface

`health`, `status`; locks (`lock_get`, `lock_acquire`, `lock_acquire_many`,
`try_lock`, `must_lock`, `lock`, `lock_release`); semaphores (`semaphore_get`,
`semaphore_acquire`, `try_semaphore`, `must_semaphore`, `semaphore`,
`semaphore_release`); idempotency (`idempotency_get`, `idempotency_claim`,
`idempotency_complete`); reader-writer locks (`rw_acquire_read`, `rw_end_read`,
`rw_acquire_write`, `rw_end_write`); config KV (`kv_get`, `kv_put`, `kv_delete`,
`kv_list`); rate limiting (`rate_limit_get`, `rate_limit_check`); cron
(`schedule_get`, `schedule_upsert`, `schedule_record_run`, `schedule_history`);
leader election (`election_get`, `election_campaign`, `election_renew`,
`election_resign`); service discovery (`service_instances`, `service_register`,
`service_heartbeat`, `service_deregister`, `service_list`). All are prefixed
`fiducia_`.

## Publishing

C has no universal package registry, so releases are distributed via **GitHub
Releases**: the orchestrator tags `clients/c/v${PACKAGE_VERSION}` and uploads
`fiducia.h` + `fiducia.c`. Run `./publish.sh --dry-run` (or `--release`) to
delegate to the shared publisher.

## License

UNLICENSED / proprietary. No open-source license has been granted for this
package yet; all rights reserved unless fiducia.cloud grants a separate license.
