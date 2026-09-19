# Fiducia RPC (`/v1/rpc`)

Fiducia's operations are reachable two ways: the existing REST endpoints, and a
single RPC envelope endpoint at `POST /v1/rpc`. This directory holds the RPC
contract.

## RPC is a projection of REST, not a second surface

Every RPC operation corresponds to exactly one REST operation in
[`../operations.json`](../operations.json), which stays the authority. The RPC
manifest is *derived* from it:

```sh
cargo run --manifest-path rpc/generator/Cargo.toml -- generate .   # write the manifest
cargo run --manifest-path rpc/generator/Cargo.toml -- check .      # determinism + staleness
```

No network, no clock, no model — output is a pure function of the input bytes.
Adding an operation means editing `operations.json` and regenerating; editing
`http-projection.json` by hand is caught by CI.

This is the whole point of the arrangement. A hand-maintained RPC surface beside
a hand-maintained REST surface drifts within weeks, and the drift is invisible
until a client calls something that no longer exists.

| File | What it is |
| --- | --- |
| `http-projection.json` | Generated. All 69 operations: key, sections, HTTP projection. Was `operations.rpc.json`, a name that read as "the RPC operations" — the semantic contract this document explicitly is not. |
| `operation-keys.json` | Generated. Flat key list for client SDKs to import. |
| `generator/` | The Rust generator and its conformance tests. |
| `contract/` | The authored contract for the *format* of the two generated files: `main.tsp` and `authored.schema.json`, independent peers compared by TJSV. The generator files its output under `contract/instances/` so TJSV validates the real artifacts against both. |

## What the generator refuses

The projection can be "69 of 69" and still be wrong, so the generator validates
what it copies rather than only copying it:

- **An HTTP method outside a closed set.** Uppercasing whatever the manifest
  said would emit `POTS`.
- **A path that is not absolute, or whose `{placeholders}` are not exactly the
  parameters declared `in: path`.** Either way the operation is unroutable. A
  path parameter marked optional is refused too: a segment cannot be omitted.
- **A parameter name declared twice in one operation,** in the same section or
  across two. Each section would be well formed and the envelope ambiguous.
- **A field in `operations.json` it does not know.** This one is here because of
  a bug. The manifest marks optionality as `optional: true`. The generator read
  a `required` field the manifest has never had, defaulted it to `true`, and
  serde silently dropped the real field — so all 63 optional parameters were
  projected as required, while every check reported 69 of 69. The unit test
  that should have caught it used `"required": false` in its fixture, a
  spelling invented to match the code. The source structs now deny unknown
  fields, a conformance test compares every parameter's optionality with the
  real manifest, and another pins the rule to the one `generate.py` applies
  (`x.get("optional")`), since the two read the same file.

## Keys

`fiducia.<group>.<operation>` — for example `fiducia.locks.lock_acquire`,
`fiducia.barriers.barrier_arrive`. Segments are lowercase and the grammar
matches the fleet-wide `rpc_key` shape, so fiducia keys are valid wherever ORES
RPC keys are accepted.

A key is the *only* identity an RPC caller uses. Method and path stay inside the
envelope's `http` projection, which exists so a reviewer can see the two
surfaces are the same operation and so the edge can route an envelope to the
handler that already serves the REST call.

## Sections

Each parameter is placed in `path`, `query` or `body` according to the `in`
field the REST manifest already declares. Nothing is inferred: a parameter whose
location is not one of those three is a hard error rather than a guess, so a new
location (a header parameter, say) has to be designed rather than silently
landing in the body.

## What this document is not

It is an **HTTP projection**, not a semantic contract, and it says so in its own
`authority` block. It records which URL each operation is reachable at. It does
not record what an operation means, whether it streams, or what its payload
types are.

Those need a handlers-authoritative Contract IR, which fiducia does not have
yet. Until then, fields whose value would be a guess are **omitted rather than
defaulted** — most importantly `stream`.

An earlier draft wrote `stream: "unary"` on all 69 operations. That was wrong:
the REST manifest cannot establish it, because a single-response HTTP endpoint
is exactly how a server-streaming operation looks before anyone declares it one.
Writing "unary" turned an absence of evidence into a contract that clients would
then rely on. A watch-style operation (`lock_watch`, `election_watch`) will be
declared `server_stream` by that Contract IR when it exists, and will reach the
*streaming* client surface, which terminates in `stream()` rather than
`makeCall()`.

## Provenance

Every generated manifest records the SHA-256 of the exact `operations.json`
bytes it was derived from, plus the generator name and version, so a manifest
can be tied back to its input without trusting the commit it happens to sit on.

The generating git commit is deliberately **not** embedded. It would make output
depend on git state rather than input bytes: the artifact would change on every
unrelated commit, the staleness check would fail constantly, and the determinism
check would stop meaning anything.

That is a split between two kinds of metadata, not an omission:

| Kind | Where it lives |
| --- | --- |
| Content identity — `source_manifest_sha256`, `generator`, `generator_version` | inside the generated bytes |
| Build provenance — repository, commit, workflow, builder identity | in a signed attestation *about* those bytes |

On a push to `main`, `rpc-manifest.yml` emits a signed build-provenance
attestation bound to the artifact's SHA-256 digest, so the commit that produced a
given manifest is recoverable without any of it leaking into the manifest
itself:

```sh
gh attestation verify rpc/http-projection.json --repo fiducia-cloud/fiducia-clients
```

## Envelope

```json
{
  "v": 1,
  "op": "call",
  "id": "<caller-chosen correlation id>",
  "key": "fiducia.locks.lock_acquire",
  "transport": "http",
  "body": { "key": "orders/checkout", "holder": "worker-a", "ttl_ms": 30000 }
}
```

The reply is the matching `receipt` envelope, correlated by `id`.

## Client SDKs

Not generated yet. The intended path is the shared fluent client from
`ORESoftware/api-docs`, which already implements this envelope along with
per-call timeouts, retries and backoff, deduplication, concurrency keys and
serialization strategy — all relevant to a coordination service, and all things
each of the 37 SDKs would otherwise reimplement differently.

That client is not published yet (see ORESoftware/api-docs#166). Writing a
fiducia-local fluent client before then would create exactly the second surface
this contract exists to prevent, so the SDK layer waits for it. `rpc/generator` and
the conformance gate are the part that can land now and are worth having
regardless.
