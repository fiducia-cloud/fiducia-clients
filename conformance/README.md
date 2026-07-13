# Conformance node harness

Boots a **single `fiducia-node`** that serves the full `/v1` coordination API, so
the language clients in `../clients/` can be run against a real live node.

A lone node self-elects leader of every shard (Raft **quorum of 1**), so no
cluster is required — one process is the whole coordination service.

## TL;DR

```bash
./run-node.sh            # build + boot one node, block until ready
./smoke.sh               # prove the /v1 API works (curl, exits non-zero on failure)
./run-node.sh down       # stop it
```

Client/data-plane API is served on **`http://localhost:8090`** (override with
`FIDUCIA_NODE_PORT`). Readiness check: `GET /healthz` or `GET /readyz` → `200`.

## Ports

| Port | Plane | Routes | Who talks to it |
|------|-------|--------|-----------------|
| **8090** | client / data | `/healthz`, `/readyz`, `/v1/*` | the conformance clients — **this is the one you want** |
| 9090 | peer / Raft | `/raft/*` | node↔node only; irrelevant for a single node, but the process still binds it |

`8090` is the client API. `9090` (`FIDUCIA_PEER_PORT`) is bound too — leave it free.

## Boot modes

`run-node.sh` has two modes (`MODE` env):

### `MODE=cargo` (default, no Docker needed)

Builds `../../fiducia-node.rs` with `cargo build --locked --release` and runs the binary.
Requires the Rust toolchain and the node repo **plus its two sibling path-dep
crates** on disk: `fiducia-node.rs`, `fiducia-routing.rs`, `fiducia-interfaces`
(all siblings under `fiducia.cloud/`). Build artifacts stay in the node repo's
own gitignored `target/`; nothing is written into this repo (the WAL data dir and
pidfile live under `$TMPDIR/fiducia-conformance/`).

This is the default because it needs no Docker daemon and rebuilds are fast.

### `MODE=docker` (hermetic)

```bash
MODE=docker ./run-node.sh          # docker compose up -d --build + wait
# or directly:
docker compose up -d --build
curl http://localhost:8090/readyz  # poll from the HOST (distroless has no curl)
docker compose down
```

Uses `docker-compose.yml`, which builds the image from the node repo's
`Dockerfile`. That Dockerfile clones the sibling `fiducia-routing` /
`fiducia-interfaces` crates during the build, so this mode needs a **reachable
Docker daemon and network access to GitHub**. First build is slow (full release
compile inside the container). Use this when you can't put the sibling repos on
disk but have Docker.

## Single-node config

The node is single-node **by default** — `NodeConfig::default()` reads the
environment and, with `FIDUCIA_PEERS` unset, boots a solo node:

| Setting | Env var | Value used here | Notes |
|---------|---------|-----------------|-------|
| Node id | `FIDUCIA_NODE_ID` | `node-a` | cosmetic for a solo node |
| Peers | `FIDUCIA_PEERS` | *(unset → `[]`)* | **empty peer set = single-node bootstrap; self-elects at t=0** |
| Shard count | `FIDUCIA_SHARD_COUNT` | `16` (default) | it leads all 16 |
| Client port | `PORT` | `8090` | `/healthz`, `/readyz`, `/v1/*` |
| Peer port | `FIDUCIA_PEER_PORT` | `9090` | `/raft/*` |
| Data dir | `FIDUCIA_DATA_DIR` | a writable temp/tmpfs dir | see gotcha ↓ |

### Gotchas (these will bite CI)

1. **`FIDUCIA_DATA_DIR` must be writable, or the node panics on boot.** The Raft
   log is now persisted to disk. The default data dir is `/var/lib/fiducia`, which
   is not writable locally (nor by the container's nonroot uid). Boot does
   `create_dir_all(<data_dir>/shard-N)` and **panics** if it fails. `run-node.sh`
   points it at a fresh temp dir; `docker-compose.yml` mounts a tmpfs at `/data`.
2. **Two listeners.** The process binds **both** `8090` and `9090`; if either
   port is taken the node exits. Free both.
3. **No auth in dev.** `FIDUCIA_INTERNAL_SECRET` is unset, so `/v1` accepts any
   caller with no header. (The node logs a WARN about this — expected.)
4. **First build is slow** (release/Docker compile of a Raft engine — minutes).
   Build once, then reuse; `run-node.sh` blocks up to 120s for readiness after start.

## Response shapes the suite asserts on

Mutations go through Raft and return a **`{committed, result:{output, ...}}`**
envelope; direct reads (KV/status) return their payload at the top level.

```jsonc
// POST /v1/locks/acquire {key,holder,ttl_ms,wait:false}
{ "committed": true, "result": { "shard": 15, "log_index": 1, "revision": 1,
  "output": { "acquired": true, "fencing_token": 1, "holder": "worker-a",
              "keys": ["orders/42"], "lease_expires_ms": 1783619657717,
              "queued": false, "revision": 1 } } }

// POST /v1/locks/release {holder,fencing_token}
{ "committed": true, "result": { "output": {
    "released": true, "keys": ["orders/42"], "promoted": [], "revision": 2 } } }

// PUT /v1/kv?key=... {value}
{ "committed": true, "result": { "output": {
    "ok": true, "key": "flags/checkout", "revision": 1, "expires_at_ms": null } } }

// GET /v1/kv?key=...   (direct read — NOT wrapped in result.output)
{ "found": true, "key": "flags/checkout",
  "entry": { "value": "on", "mod_revision": 1, "expires_at_ms": null } }

// POST /v1/idempotency/claim {key,owner,ttl_ms}
{ "committed": true, "result": { "output": {
    "claimed": true, "duplicate": false, "fencing_token": 1,
    "key": "stripe-webhook/event_123", "lease_expires_ms": 1783706037027,
    "record": { "owner": "worker-a", "status": "claimed", "fencing_token": 1,
                "first_seen_ms": 1783619637027, "metadata": {},
                "key": "stripe-webhook/event_123", "lease_expires_ms": 1783706037027 },
    "revision": 1 } } }
// a duplicate claim (different owner) replays the record: claimed=false, duplicate=true,
// record.owner stays the ORIGINAL owner.
```

The full endpoint contract is in `../ENDPOINTS.md`.

## Files

| File | What |
|------|------|
| `run-node.sh` | boot one node (cargo default, docker optional) + wait for readiness; `down` to stop |
| `smoke.sh` | curl proof of the `/v1` API (healthz, status, lock, kv, idempotency) |
| `docker-compose.yml` | hermetic single-node boot via the node repo's Dockerfile |
| `README.md` | this file |
