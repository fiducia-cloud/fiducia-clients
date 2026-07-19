# fiducia-clients

Official client libraries for [fiducia.cloud](https://fiducia.cloud) — the
Raft-replicated coordination service. **HTTP only** (no TCP). Every client is a
thin, dependency-light wrapper over one shared contract, so they all expose the
same operations with a language-idiomatic surface.

Unlike a lock-only client, these cover the **whole** API: locks, semaphores,
idempotency keys, reader-writer locks, rate limiting, cron/scheduling,
**config KV**, **leader election**, and **service discovery**.

## The contract

[`operations.json`](operations.json) is the machine-readable source for endpoint
generation; [`PROTOCOL.md`](PROTOCOL.md) is the reviewed narrative contract.
The production-tier templates under [`templates/`](templates/) retain transport
hardening and language-idiomatic helpers while `generate.py` inserts newer
manifest operations into explicit generated regions.

## Languages

First hard-gated tier: TypeScript, Go, Rust, and Python. The remaining languages
stay generated/thin so they can follow the same protocol without inventing a
second API shape. "Hard-gated" describes offline CI coverage, not uniform public
authentication or hosted-service release readiness; see below.

Every supported language's publishable artifact is also a required CI gate:
the packaging workflow installs or compiles from the produced artifact outside
the repository tree, so a client cannot appear healthy only because local source
paths happen to resolve. MATLAB remains excluded because no licensed runner is
available; it is not represented as a verified release artifact.

Each lives under [`clients/`](clients/):

| Language | Dir | HTTP via |
|----------|-----|----------|
| TypeScript | [`clients/ts`](clients/ts) | `fetch` (stdlib) |
| Python | [`clients/python`](clients/python) | `urllib` (stdlib) |
| Go | [`clients/go`](clients/go) | `net/http` (stdlib) |
| Rust | [`clients/rust`](clients/rust) | `ureq` (blocking) |
| Rust → WebAssembly | [`clients/rust-wasm`](clients/rust-wasm) | global `fetch` (`wasm-bindgen` + `web-sys`; browser/worker/Node) |
| Java | [`clients/java`](clients/java) | `java.net.http` (JDK 11+) |
| C# | [`clients/csharp`](clients/csharp) | `HttpClient` (.NET) |
| Ruby | [`clients/ruby`](clients/ruby) | `net/http` (stdlib) |
| PHP | [`clients/php`](clients/php) | `curl` (stdlib) |
| Shell | [`clients/shell`](clients/shell) | `curl` (+ `jq`) |
| PowerShell | [`clients/powershell`](clients/powershell) | `Invoke-RestMethod` |
| Dart | [`clients/dart`](clients/dart) | `dart:io` (stdlib) |
| Elixir | [`clients/elixir`](clients/elixir) | `:httpc` + `:json` (OTP 27+) |
| Gleam | [`clients/gleam`](clients/gleam) | `gleam_httpc` + `gleam_json` |
| F# | [`clients/fsharp`](clients/fsharp) | `HttpClient` + `System.Text.Json` (.NET) |
| OCaml | [`clients/ocaml`](clients/ocaml) | `ezcurl` + `yojson` |
| Clojure | [`clients/clojure`](clients/clojure) | `java.net.http` + `data.json` |
| Scala | [`clients/scala`](clients/scala) | `java.net.http` + `ujson` |
| Kotlin | [`clients/kotlin`](clients/kotlin) | `java.net.http` + `kotlinx.serialization` |
| Erlang | [`clients/erlang`](clients/erlang) | `httpc` + `json` (OTP 27+) |
| Swift | [`clients/swift`](clients/swift) | `URLSession` (Foundation) |
| C++ | [`clients/cpp`](clients/cpp) | `libcurl` + `nlohmann/json` |
| C | [`clients/c`](clients/c) | `libcurl` (bring your own JSON) |
| Zig | [`clients/zig`](clients/zig) | `std.http` + `std.json` (stdlib) |
| Haskell | [`clients/haskell`](clients/haskell) | `http-client` + `aeson` |
| Julia | [`clients/julia`](clients/julia) | `HTTP.jl` + `JSON.jl` |
| R | [`clients/r`](clients/r) | `httr` + `jsonlite` |
| MATLAB | [`clients/matlab`](clients/matlab) | `webread`/`webwrite` + `jsondecode` |
| Nim | [`clients/nim`](clients/nim) | `std/httpclient` + `std/json` (stdlib) |
| Crystal | [`clients/crystal`](clients/crystal) | `HTTP::Client` + `JSON` (stdlib) |
| Lua | [`clients/lua`](clients/lua) | `luasocket`/`luasec` + `dkjson` |

## Shape (same everywhere)

```ts
const c = new FiduciaClient("https://api.fiducia.cloud");

// lock (mutex)
const maybeLock = await c.tryLock("orders/checkout", {
  holder: "worker-a",
  ttlMs: 30000,
});
if (maybeLock.committed) {
  await c.lockRelease("orders/checkout", {
    holder: "worker-a",
    fencingToken: maybeLock.result.output.fencing_token,
  });
}

const lock = await c.mustLock("orders/checkout", {
  holder: "worker-a",
  ttlMs: 30000,
  lockRequestTimeoutMs: 5000,
  maxRetries: 2,
});
await c.lockRelease("orders/checkout", {
  holder: "worker-a",
  fencingToken: lock.result.output.fencing_token,
});

// multi-key union lock
const combo = await c.lockMany({
  keys: ["orders/checkout", "inventory/sku-42"],
  holder: "worker-a",
  ttlMs: 30000,
});
await c.lockRelease("orders/checkout", {
  holder: "worker-a",
  fencingToken: combo.result.output.fencing_token,
});

// semaphore
const slot = await c.mustSemaphore("webhook-delivery", {
  holder: "worker-b",
  ttlMs: 30000,
  max: 12,
});
await c.semaphoreRelease("webhook-delivery", {
  holder: "worker-b",
  fencingToken: slot.result.output.fencing_token,
});

// idempotency
const claim = await c.idempotencyClaim("stripe-webhook/event_123", {
  owner: "worker-a",
  ttl: "24h",
  metadata: { source: "stripe" },
});
if (claim.result.output.status === "claimed") {
  await c.idempotencyComplete("stripe-webhook/event_123", {
    owner: "worker-a",
    fencingToken: claim.result.output.fencing_token,
    result: { status: "ok" },
  });
}

// rate limiting
await c.rateLimitCheck("tenant-a", "checkout", {
  algorithm: "token_bucket",
  limit: 100,
  windowMs: 60000,
});

// scheduling
await c.scheduleUpsert("nightly", {
  cron: "0 0 * * *",
  target: { kind: "webhook", url: "https://example.com/hook" },
});

// reader-writer
const r = await c.rwAcquireRead("report");      await c.rwEndRead("report", r.lock_id);

// config KV
await c.kvPut("flags/new-ui", "on", {
  ttlMs: 60000,
  idempotencyKey: "req_01J4Y3M8C9T9",
});
const v = await c.kvGet("flags/new-ui");

// leader election
const campaign = await c.electionCampaign("prod/invoice-reconciler/leader", "pod-a", 15000, {
  metadata: {
    service: "invoice-reconciler",
    region: "us-east-1",
    version: "2026.06.27",
    address: "10.2.4.18:8080",
  },
});

// service discovery
await c.serviceRegister("api", "i-1", "10.0.0.1:9000", 10000, {
  region: "us-east-1",
  version: "blue",
});
const live = await c.serviceInstances("api");
const sameRegion = await c.serviceInstances("api", { region: "us-east-1" });
const currentLeaders = await c.serviceInstances("api", { leader: "true" });
```

Across client languages, the try helpers force `wait:false` and the must/short
helpers force `wait:true` using language-idiomatic casing (`tryLock`,
`try_lock`, `TryLock`, etc.). Blocking lock and semaphore calls can be bounded
with each client's timeout, retry count, retry delay, and cancellation/context
controls where that runtime supports them. Mutating request controls also accept
customer retry idempotency keys: TypeScript `idempotencyKey`, Python
`idempotency_key`, Go `IdempotencyKey`, and Rust
`RequestControl.idempotency_key`.

The first-tier high-level lock clients generate two independent cryptographic
identities: a holder for the worker (unless the caller supplies one), and a new
`request_id` for each logical acquisition attempt. The request ID is reused for
every queued retry and the matching cancel, then discarded. This makes an
ambiguous acquire safe to cancel even when cancel reaches Raft first, without
tombstoning a caller-supplied holder or blocking its next attempt. Thin methods
accept an optional request ID for callers implementing their own retry loop;
omitting it keeps the legacy wire behavior during rolling upgrades.
If the node cannot durably record an attempt cancellation because its bounded
tombstone table is full, it returns `reason:"cancellation_capacity"`. High-level
clients surface that condition (and any failed raced-grant release) as an error;
they never report a safe timeout while an ambiguous acquire could still commit.

TypeScript, Python, and Go retry non-idempotent requests only when the caller
supplies one stable `Idempotency-Key`; they never invent a header that could
falsely imply replay safety at a direct node. That header is consumed by the
hosted edge/load-balancer path. Callers pointed straight at a fiducia-node must
rely on the primitive's documented idempotence or avoid ambiguous mutation
retries because the node does not provide the customer HTTP-header replay
ledger. Retrying GET/HEAD and single-shot mutations remain keyless.
The Rust client never invents a customer key: ambiguous transport/5xx retries
there require `RequestControl.idempotency_key` (broker-style `429`/`503`
rejections remain retryable because the server rejected them before applying
the operation). First-tier default transports also refuse HTTP redirects so a
mutation and its credentials cannot be replayed to `Location`; injected custom
Go/TypeScript transports must preserve that no-redirect policy themselves.

For the hosted B2B flow, each service replica registers itself, campaigns for a
named role, renews before its lease expires, and stops leader-only work if renew
fails or returns `not_leader`. The winning replica gets a monotonic
`fencing_token`; pass that token to downstream databases, queues, or external
systems so stale leaders can be rejected after failover. Discovery metadata is
an exact-match string map, so leader-aware clients can filter on fields such as
`leader=true`, `region=us-east-1`, or `version=blue` while SSE watches track
election and service changes.

## WebAssembly

[`clients/rust-wasm`](clients/rust-wasm) is the Rust client compiled to
WebAssembly. It cannot open sockets like the blocking `clients/rust` build, so
its transport is the global `fetch` (resolved from the global scope via
`wasm-bindgen` + `js-sys`, so it works on the browser main thread, in Web
Workers, and in Node 18+/Deno). Its `src/lib.rs` is generated from
`operations.json` — every operation is an `async` method, exported to JS as
camelCase, that resolves to the parsed JSON response (or rejects with
`{ status, body }`):

```sh
python3 generate.py rust-wasm                 # (re)generate clients/rust-wasm/src/lib.rs
wasm-pack build clients/rust-wasm --target web -- --locked # -> pkg/ with .wasm + .d.ts
```

```js
import init, { FiduciaClient } from "./pkg/fiducia_client_wasm.js";
await init();
const c = new FiduciaClient("https://api.fiducia.cloud", 5000); // optional per-request timeout (ms)
c.setHeader("Authorization", "Bearer <token>"); // default header on every request
const lock = await c.lockAcquire("orders/checkout", "worker-a", 30000, false);
await c.lockRelease("worker-a", lock.result.output.fencing_token);
// c.setTimeoutMs(10000);         // adjust/clear the timeout (undefined = none)
// c.setHeader("Idempotency-Key", key); c.removeHeader("Idempotency-Key");
```

Each call resolves to the parsed JSON, or rejects with `{ status, body }` — `status`
is the HTTP code (or `0` for a transport error / timeout), and `body` is the
parsed JSON, or the raw text when the response isn't JSON.

## CLI

The Python client doubles as a dependency-free CLI for local smoke checks and
operator scripts. The packaged `fiducia` entry point runs `fiducia.py:main` and
reads `FIDUCIA_BASE_URL` plus optional `FIDUCIA_TIMEOUT_SECONDS`:

```sh
FIDUCIA_BASE_URL=https://api.fiducia.cloud \
  python3 clients/python/fiducia.py lock acquire orders/checkout --holder worker-a --ttl-ms 30000

python3 clients/python/fiducia.py kv put flags/new-ui on --prev-revision 0
python3 clients/python/fiducia.py idempotency claim stripe-webhook/event_123 --owner worker-a --ttl 24h
python3 clients/python/fiducia.py rate-limit check tenant-a checkout --algorithm token_bucket --limit 100 --window-ms 60000
python3 clients/python/fiducia.py cron upsert nightly --cron "0 0 * * *" --target-kind webhook --target-url https://example.com/hook
python3 clients/python/fiducia.py election campaign cron-main node-a --ttl-ms 15000 --metadata region=us-east-1 --metadata address=10.2.4.18:8080
python3 clients/python/fiducia.py service register api i-1 10.0.0.1:9000 --ttl-ms 10000 --metadata az=a
```

The CLI currently has no bearer-token or API-key flag. Use it only with an
endpoint that intentionally permits unauthenticated access (for example a
local development endpoint); it is not yet a hosted-customer login client.

## Reproducible build inputs

The Rust client lockfiles are committed, and CI/container Cargo commands use
`--locked`. The Rust manifest pins `fiducia-interfaces` directly by Git revision;
languages that consume the sibling checkout are tested against the same reviewed
full commit `6e20a3f4df2e52b99a0ad6add83d4528262b5dbc`, never the moving default branch.
The Dockerfile fetches that object directly, verifies `FETCH_HEAD`, checks out a
detached `HEAD`, and verifies it again; overrides that are branches, tags, short
hashes, or a different object fail the build. Update the CI checkout pins, Rust
manifest/lockfile, and Docker argument together when adopting a new contract.
The multi-language test image installs system tools as root, then switches to
numeric UID/GID `10001:10001` before fetching contracts, copying source,
compiling, or running tests. CI audits the TypeScript and both Rust lockfiles in
addition to the language-specific test suites.

## Status

Clients track the live node endpoints for locks, semaphores, idempotency keys,
multi-key locks, rate limiting, cron/scheduling, KV, elections, and discovery.
TypeScript and Python include SSE watch helpers for KV key/prefix changes,
election leadership changes, and service discovery changes. Production-tier
clients also expose request timeout and bounded retry controls around blocking
acquisition calls.

The TypeScript, Python, Go, and Rust jobs are required CI checks, as is generator
drift. That verifies compilation and offline wire behavior. It does not by itself
mean every client is ready to call an authentication-required public endpoint.

## Authentication readiness

Authentication support is currently uneven and must not be inferred from a
placeholder in an example:

- Rust-Wasm can attach `Authorization` with `setHeader`.
- TypeScript callers can inject a `fetch` wrapper, and Go callers can provide a
  custom `http.Client`/`RoundTripper`, to add public authentication headers.
- The native Python and Rust clients do not yet expose a general public bearer
  or API-key option. The Python CLI likewise has no auth flag.
- Rust `FiduciaClient::internal(...)` is only for the trusted service-to-node
  hop. It sends `x-fiducia-internal-auth` and tenant scope, rejects redirects,
  and redacts those values from debug formatting. It is not customer auth.

Until a native client has an explicit public-auth path, do not point it directly
at an auth-required hosted endpoint and assume credentials will be attached.

## Security posture

- **No embedded secrets.** No real API keys, tokens, or private endpoints are
  baked into any client, example, or test. Where a client supports
  caller-supplied headers, docs use placeholders such as `Bearer <token>` only;
  unsupported clients do not silently invent or discover credentials.
- **Publish scripts don't leak secrets.** `scripts/publish-common.sh` and the
  per-language `clients/*/publish.sh` handle version/tag plumbing and registry
  commands; they never `echo` tokens, and registry credentials come from the
  environment / the ecosystem's own credential store, not from this repo.
- **Dependency footprint is minimal.** Clients lean on each language's standard
  library (see the Languages table); the TypeScript client uses `fetch` with no
  runtime dependencies. The `tools/flags-2-env` submodule is vendored tooling and
  is out of scope for this repo's audit.

## Related

- [`fiducia-load-balance.rs`](https://github.com/fiducia-cloud/fiducia-load-balance.rs) — the endpoint clients hit.
- [`fiducia-node.rs`](https://github.com/fiducia-cloud/fiducia-node.rs) — the coordination engine.
- [`fiducia-cli.rs`](https://github.com/fiducia-cloud/fiducia-cli.rs) — `fiduciactl`-style operator/customer CLI, starting with closest-region selection.
